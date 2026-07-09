import DBCore
import Foundation
import Logging
import NIOCore
import NIOPosix
@preconcurrency import RediStack

public final class RedisDriver: DatabaseDriver, Sendable {
    public static let descriptor = DriverDescriptor(
        id: "redis",
        displayName: "Redis",
        queryLanguage: .redis,
        defaultPort: 6379,
        supportsStreaming: true,
        supportsServerSideCancel: false,
        identifierQuote: ""
    )

    private let state: ConnectionActor

    public init(config: ResolvedConnectionConfig) throws {
        self.state = ConnectionActor(config: config)
    }

    public func connect() async throws {
        try await state.connect()
    }

    public func disconnect() async {
        await state.disconnect()
    }

    public func listNamespaces(parent: Namespace?) async throws -> [Namespace] {
        guard parent == nil else { return [] }
        // One keyspace node; browsing it runs a SCAN with the filter as a
        // MATCH pattern. Use SELECT in a query tab to switch databases.
        let index = await state.databaseIndex
        return [Namespace(path: ["db\(index)"], kind: .table(.table), isExpandable: false)]
    }

    public func listColumns(of table: Namespace) async throws -> [ColumnMeta] {
        []  // keyspaces have no columns
    }

    public func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        guard case .sql(let text) = query else {
            throw DBError(kind: .unsupported, message: "Redis driver only accepts commands")
        }
        let tokens = RedisCommandParser.tokenize(text)
        guard let command = tokens.first else {
            throw DBError(kind: .queryFailed, message: "Empty command")
        }
        if command.uppercased() == "SCAN" {
            let options = try RedisCommandParser.scanOptions(tokens)
            return await state.scan(options: options, pageSize: pageSize)
        }
        return try await state.send(
            command: command, arguments: Array(tokens.dropFirst()))
    }
}

// MARK: - Command parsing

enum RedisCommandParser {
    /// Splits a command line into tokens, honoring single/double quotes.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for char in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let active = quote {
                if char == active {
                    quote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                quote = char
                hasToken = true
            } else if char.isWhitespace {
                if hasToken || !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(char)
            }
        }
        if hasToken || !current.isEmpty { tokens.append(current) }
        return tokens
    }

    struct ScanOptions {
        var match: String = "*"
        /// Total number of keys to return (the table browser's row limit).
        var count: Int = 100
    }

    static func scanOptions(_ tokens: [String]) throws -> ScanOptions {
        var options = ScanOptions()
        var index = 2  // skip "SCAN" and the cursor
        while index < tokens.count {
            switch tokens[index].uppercased() {
            case "MATCH":
                guard index + 1 < tokens.count else {
                    throw DBError(kind: .queryFailed, message: "MATCH needs a pattern")
                }
                options.match = tokens[index + 1]
                index += 2
            case "COUNT":
                guard index + 1 < tokens.count, let count = Int(tokens[index + 1]) else {
                    throw DBError(kind: .queryFailed, message: "COUNT needs a number")
                }
                options.count = count
                index += 2
            default:
                throw DBError(
                    kind: .queryFailed,
                    message: "Unsupported SCAN option: \(tokens[index])")
            }
        }
        return options
    }
}

// MARK: - Connection actor

private actor ConnectionActor {
    private let config: ResolvedConnectionConfig
    private var connection: RedisConnection?
    let databaseIndex: Int

    init(config: ResolvedConnectionConfig) {
        self.config = config
        self.databaseIndex = config.database.flatMap(Int.init) ?? 0
    }

    func connect() async throws {
        guard connection == nil else { return }
        do {
            let configuration = try RedisConnection.Configuration(
                hostname: config.host ?? "localhost",
                port: config.port ?? 6379,
                password: config.password,
                initialDatabase: databaseIndex
            )
            connection = try await RedisConnection.make(
                configuration: configuration,
                boundEventLoop: MultiThreadedEventLoopGroup.singleton.any()
            ).get()
        } catch let error as DBError {
            throw error
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not connect to Redis",
                underlying: String(reflecting: error))
        }
    }

    func disconnect() async {
        try? await connection?.close().get()
        connection = nil
    }

    private func requireConnection() throws -> RedisConnection {
        guard let connection else {
            throw DBError(kind: .connectionFailed, message: "Not connected")
        }
        return connection
    }

    /// Generic single-command execution; array replies become one row each.
    func send(command: String, arguments: [String]) async throws -> QueryExecution {
        let connection = try requireConnection()
        let reply: RESPValue
        do {
            reply = try await connection.send(
                command: command.uppercased(),
                with: arguments.map { RESPValue(from: $0) }
            ).get()
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: (error as? RedisError)?.message ?? "Command failed",
                underlying: String(reflecting: error))
        }

        let rows = Self.rows(for: reply)
        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
            .makeStream()
        continuation.yield(QueryResultChunk(rows: rows, isFinal: true))
        continuation.finish()
        return QueryExecution(
            columns: [ColumnMeta(name: "value", dbTypeName: "resp")],
            chunks: stream,
            cancel: {})
    }

    /// Full SCAN iteration: follows the cursor until done or `options.count`
    /// keys were emitted, streaming in pageSize chunks.
    func scan(
        options: RedisCommandParser.ScanOptions, pageSize: Int
    ) async -> QueryExecution {
        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
            .makeStream()

        let producer = Task {
            do {
                let connection = try requireConnection()
                var cursor = 0
                var emitted = 0
                var buffer: [ResultRow] = []
                repeat {
                    let (next, keys) = try await connection.scan(
                        startingFrom: cursor,
                        matching: options.match == "*" ? nil : options.match,
                        count: min(pageSize, 1000)
                    ).get()
                    cursor = next
                    for key in keys {
                        guard emitted < options.count else { break }
                        buffer.append(ResultRow(
                            id: emitted, values: [.string(key)]))
                        emitted += 1
                        if buffer.count >= pageSize {
                            continuation.yield(QueryResultChunk(rows: buffer, isFinal: false))
                            buffer = []
                        }
                    }
                    try Task.checkCancellation()
                } while cursor != 0 && emitted < options.count
                continuation.yield(QueryResultChunk(rows: buffer, isFinal: true))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: DBError(kind: .cancelled, message: "Query cancelled"))
            } catch {
                continuation.finish(throwing: DBError(
                    kind: .queryFailed,
                    message: "SCAN failed",
                    underlying: String(reflecting: error)))
            }
        }
        continuation.onTermination = { _ in producer.cancel() }

        return QueryExecution(
            columns: [ColumnMeta(name: "key", dbTypeName: "string")],
            chunks: stream,
            cancel: { producer.cancel() })
    }

    // MARK: RESP mapping

    static func rows(for reply: RESPValue) -> [ResultRow] {
        switch reply {
        case .array(let elements):
            return elements.enumerated().map { index, element in
                ResultRow(id: index, values: [value(for: element)])
            }
        default:
            return [ResultRow(id: 0, values: [value(for: reply)])]
        }
    }

    static func value(for reply: RESPValue) -> DBValue {
        switch reply {
        case .null:
            return .null
        case .simpleString, .bulkString:
            return .string(reply.string ?? "")
        case .integer(let int):
            return .int(Int64(int))
        case .error(let error):
            return .string("ERR \(error.message)")
        case .array(let elements):
            return .array(elements.map { value(for: $0) })
        }
    }
}
