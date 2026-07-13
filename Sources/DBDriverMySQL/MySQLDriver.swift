import DBCore
import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

public final class MySQLDriver: DatabaseDriver, Sendable {
    public static let descriptor = DriverDescriptor(
        id: "mysql",
        displayName: "MySQL / MariaDB",
        queryLanguage: .sql,
        defaultPort: 3306,
        supportsStreaming: true,
        supportsServerSideCancel: true,
        identifierQuote: "`",
        sqlDialect: .mysql,
        supportsTableEditing: true,
        supportsDDL: true,
        // ANALYZE deferred: MySQL emits TREE-format text until 8.3.
        explainSupport: .plan,
        activeNamespaceKind: .database
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
        switch parent?.kind {
        case nil:
            let rows = try await state.collect("SHOW DATABASES", binds: [])
            return rows.compactMap { row in
                guard case .string(let name) = row.first else { return nil }
                return Namespace(path: [name], kind: .database, isExpandable: true)
            }
            .sorted { $0.name < $1.name }
        case .database:
            let database = parent!.name
            let rows = try await state.collect(
                """
                SELECT table_name, table_type FROM information_schema.tables
                WHERE table_schema = ? ORDER BY table_name
                """,
                binds: [MySQLData(string: database)])
            return rows.compactMap { row in
                guard case .string(let name) = row.first,
                      case .string(let type) = row.dropFirst().first
                else { return nil }
                let kind: TableKind = type == "VIEW" ? .view : .table
                return Namespace(
                    path: parent!.path + [name], kind: .table(kind), isExpandable: false)
            }
        default:
            return []
        }
    }

    public func listColumns(of table: Namespace) async throws -> [ColumnMeta] {
        guard table.path.count == 2 else { return [] }
        let rows = try await state.collect(
            """
            SELECT column_name, data_type FROM information_schema.columns
            WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position
            """,
            binds: [MySQLData(string: table.path[0]), MySQLData(string: table.path[1])])
        return rows.compactMap { row in
            guard case .string(let column) = row.first,
                  case .string(let type) = row.dropFirst().first
            else { return nil }
            return ColumnMeta(name: column, dbTypeName: type)
        }
    }

    public func describeTable(_ table: Namespace) async throws -> TableStructure {
        guard table.path.count == 2 else {
            return TableStructure(columns: [], indexes: [])
        }
        let binds = [MySQLData(string: table.path[0]), MySQLData(string: table.path[1])]

        let columnRows = try await state.collect(
            """
            SELECT column_name, column_type, is_nullable, column_default, column_key
            FROM information_schema.columns
            WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position
            """,
            binds: binds)
        let columns: [ColumnDetail] = columnRows.compactMap { row in
            guard case .string(let column) = row[safe: 0],
                  case .string(let type) = row[safe: 1],
                  case .string(let nullable) = row[safe: 2]
            else { return nil }
            var defaultValue: String?
            if case .string(let text) = row[safe: 3] { defaultValue = text }
            var isPrimary = false
            if case .string(let key) = row[safe: 4] { isPrimary = key == "PRI" }
            return ColumnDetail(
                name: column,
                dbTypeName: type,
                isNullable: nullable == "YES",
                defaultValue: defaultValue,
                isPrimaryKey: isPrimary)
        }

        let indexRows = try await state.collect(
            """
            SELECT index_name, non_unique, index_type, column_name
            FROM information_schema.statistics
            WHERE table_schema = ? AND table_name = ?
            ORDER BY index_name, seq_in_index
            """,
            binds: binds)
        // One row per indexed column; fold into one IndexInfo per index name,
        // preserving the server's index ordering.
        var order: [String] = []
        var grouped: [String: (unique: Bool, type: String?, columns: [String])] = [:]
        for row in indexRows {
            guard case .string(let indexName) = row[safe: 0] else { continue }
            var nonUnique = true
            switch row[safe: 1] {
            case .int(let value): nonUnique = value != 0
            case .string(let value): nonUnique = value != "0"
            default: break
            }
            var type: String?
            if case .string(let text) = row[safe: 2] { type = text }
            var column = "(expression)"
            if case .string(let name) = row[safe: 3] { column = name }
            if grouped[indexName] == nil {
                order.append(indexName)
                grouped[indexName] = (unique: !nonUnique, type: type, columns: [])
            }
            grouped[indexName]?.columns.append(column)
        }
        let indexes: [IndexInfo] = order.compactMap { name in
            guard let entry = grouped[name] else { return nil }
            return IndexInfo(
                name: name,
                columns: entry.columns,
                isUnique: entry.unique,
                isPrimary: name == "PRIMARY",
                method: entry.type)
        }
        .sorted { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }

        return TableStructure(columns: columns, indexes: indexes)
    }

    public func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        guard case .sql(let sql) = query else {
            throw DBError(kind: .unsupported, message: "MySQL driver only accepts SQL")
        }
        return try await state.execute(sql: sql, pageSize: pageSize)
    }

    /// Overrides the DBCore default: `USE` is rejected by the prepared-
    /// statement protocol the normal execute path speaks, so it runs over
    /// the text protocol, and the actor remembers it across reconnects.
    public func setActiveNamespace(_ name: String?) async throws {
        guard let name else {
            throw DBError(
                kind: .unsupported,
                message: "MySQL has no default-database reset; switch to a "
                    + "specific database instead")
        }
        try await state.setActiveDatabase(name)
    }
}

extension Array where Element == DBValue {
    subscript(safe index: Int) -> DBValue? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Connection actor

private actor ConnectionActor {
    private let config: ResolvedConnectionConfig
    private let logger = Logger(label: "dbosk.mysql")
    private var connection: MySQLConnection?
    /// Server thread id of our connection, used for KILL QUERY.
    private var threadID: Int?
    /// In-flight streaming query, tracked so cancellation can wait for the
    /// command to fully unwind before the connection is touched again.
    private var currentQuery: EventLoopFuture<Void>?
    /// Database switched to via USE, reapplied after transparent reconnects.
    private var activeDatabase: String?

    init(config: ResolvedConnectionConfig) {
        self.config = config
    }

    func connect() async throws {
        guard connection == nil else { return }
        do {
            let conn = try await Self.open(config: config, logger: logger)
            connection = conn
            let rows = try await conn.query("SELECT CONNECTION_ID()").get()
            threadID = rows.first.flatMap { row in
                row.columnDefinitions.first.flatMap {
                    row.column($0.name)?.int
                }
            }
            if let activeDatabase {
                _ = try await conn.simpleQuery(
                    Self.useStatement(for: activeDatabase)).get()
            }
        } catch let error as DBError {
            throw error
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not connect to MySQL",
                underlying: String(reflecting: error))
        }
    }

    private static func open(
        config: ResolvedConnectionConfig, logger: Logger
    ) async throws -> MySQLConnection {
        let host = config.host ?? "localhost"
        let port = config.port ?? 3306
        let address = try SocketAddress.makeAddressResolvingHost(host, port: port)

        let tls: TLSConfiguration?
        switch config.tls {
        case .disabled:
            tls = nil
        case .preferred:
            // Accept self-signed server certs (the common on-prem setup);
            // `required` enforces full verification.
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            tls = configuration
        case .required:
            tls = .makeClientConfiguration()
        }

        return try await MySQLConnection.connect(
            to: address,
            username: config.user ?? "root",
            database: config.database ?? "information_schema",
            password: config.password,
            tlsConfiguration: tls,
            // SNI must be a hostname; IP literals are rejected by NIOSSL.
            serverHostname: isIPAddress(host) ? nil : host,
            logger: logger,
            on: MultiThreadedEventLoopGroup.singleton.any()
        ).get()
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    func disconnect() async {
        try? await connection?.close().get()
        connection = nil
    }

    /// Returns the live connection, transparently reconnecting if it was
    /// discarded (e.g. after a KILL QUERY left it in a dirty state).
    private func requireConnection() async throws -> MySQLConnection {
        if let connection { return connection }
        try await connect()
        guard let connection else {
            throw DBError(kind: .connectionFailed, message: "Not connected")
        }
        return connection
    }

    /// Kills the running query server-side, waits for the interrupted command
    /// to unwind (closing the channel mid-command races MySQLNIO's internal
    /// command queue), then discards the connection; the next query reconnects.
    func killCurrentQuery() async {
        guard let threadID else { return }
        if let side = try? await Self.open(config: config, logger: logger) {
            _ = try? await side.query("KILL QUERY \(threadID)").get()
            try? await side.close().get()
        }
        if let currentQuery {
            _ = try? await currentQuery.get()
        }
        currentQuery = nil
        try? await connection?.close().get()
        connection = nil
    }

    /// Switches the connection's default database. Runs over the text
    /// protocol (`USE` is rejected by the prepared-statement protocol that
    /// `query` speaks) and is remembered so transparent reconnects (e.g.
    /// after KILL QUERY) restore it instead of silently reverting to the
    /// configured database.
    func setActiveDatabase(_ name: String) async throws {
        let connection = try await requireConnection()
        do {
            _ = try await connection.simpleQuery(Self.useStatement(for: name)).get()
            activeDatabase = name
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: Self.friendlyMessage(for: error),
                underlying: String(reflecting: error))
        }
    }

    private static func useStatement(for name: String) -> String {
        ActiveNamespaceStatementBuilder.statement(activating: name, dialect: .mysql)
            ?? "USE `\(name)`"
    }

    func collect(_ sql: String, binds: [MySQLData]) async throws -> [[DBValue]] {
        let connection = try await requireConnection()
        do {
            let rows = try await connection.query(sql, binds).get()
            return rows.map { row in
                MySQLValueMapper.values(for: row)
            }
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: Self.friendlyMessage(for: error),
                underlying: String(reflecting: error))
        }
    }

    func execute(sql: String, pageSize: Int) async throws -> QueryExecution {
        let connection = try await requireConnection()

        // MySQLNIO delivers rows via callback with no flow control, so rows are
        // buffered into an unbounded stream. Server-side KILL QUERY is the only
        // way to stop a huge result early.
        let (rowStream, rowContinuation) = AsyncThrowingStream<MySQLRow, Error>
            .makeStream()
        let affected = AffectedBox()

        let queryFuture = connection.query(
            sql,
            onRow: { row in rowContinuation.yield(row) },
            onMetadata: { metadata in affected.set(Int(metadata.affectedRows)) }
        )
        currentQuery = queryFuture
        queryFuture.whenComplete { result in
            switch result {
            case .success: rowContinuation.finish()
            case .failure(let error): rowContinuation.finish(throwing: error)
            }
        }

        // Peek the first row for column metadata.
        var iterator = rowStream.makeAsyncIterator()
        let firstRow: MySQLRow?
        do {
            firstRow = try await iterator.next()
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: Self.friendlyMessage(for: error),
                underlying: String(reflecting: error))
        }

        let columns: [ColumnMeta] = (firstRow?.columnDefinitions.map {
            ColumnMeta(name: $0.name, dbTypeName: $0.columnType.description)
        }) ?? []

        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
            .makeStream()

        let producer = Task {
            var buffer: [ResultRow] = []
            var index = 0
            func flush(final: Bool) {
                continuation.yield(QueryResultChunk(
                    rows: buffer, isFinal: final, affectedCount: affected.value))
                buffer = []
            }
            do {
                if let firstRow {
                    buffer.append(ResultRow(
                        id: index, values: MySQLValueMapper.values(for: firstRow)))
                    index += 1
                }
                while let row = try await iterator.next() {
                    buffer.append(ResultRow(
                        id: index, values: MySQLValueMapper.values(for: row)))
                    index += 1
                    if buffer.count >= pageSize {
                        flush(final: false)
                    }
                    try Task.checkCancellation()
                }
                flush(final: true)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: DBError(kind: .cancelled, message: "Query cancelled"))
            } catch {
                continuation.finish(throwing: DBError(
                    kind: .queryFailed,
                    message: Self.friendlyMessage(for: error),
                    underlying: String(reflecting: error)))
            }
        }

        let cancel: @Sendable () async -> Void = { [weak self] in
            producer.cancel()
            await self?.killCurrentQuery()
        }
        continuation.onTermination = { _ in producer.cancel() }

        return QueryExecution(columns: columns, chunks: stream, cancel: cancel)
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            switch mysqlError {
            case .server(let packet):
                return packet.errorMessage
            default:
                return String(describing: mysqlError)
            }
        }
        return "Query failed"
    }
}

/// Thread-safe box for the affected-rows metadata callback.
private final class AffectedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        stored = value
    }
}

// MARK: - Value mapping

enum MySQLValueMapper {
    static func values(for row: MySQLRow) -> [DBValue] {
        zip(row.columnDefinitions, row.values).map { column, buffer in
            let data = MySQLData(
                type: column.columnType,
                format: row.format,
                buffer: buffer,
                isUnsigned: column.flags.contains(.COLUMN_UNSIGNED))
            return value(for: data, column: column)
        }
    }

    static func value(
        for data: MySQLData, column: MySQLProtocol.ColumnDefinition41
    ) -> DBValue {
        if data.buffer == nil { return .null }
        let type = data.type
        switch type {
        case .null:
            return .null
        case .tiny:
            // tiny(1) is the conventional MySQL boolean.
            if column.columnLength == 1, let bool = data.bool { return .bool(bool) }
            return data.int64.map { .int($0) } ?? fallback(data, column)
        case .short, .int24, .long, .longlong, .year:
            if let int = data.int64 { return .int(int) }
            // Unsigned 64-bit values beyond Int64 come back as text.
            return fallback(data, column)
        case .float, .double:
            return data.double.map { .double($0) } ?? fallback(data, column)
        case .decimal, .newdecimal:
            // Sent as a text payload even in the binary protocol, but not
            // covered by MySQLData.string.
            return bufferText(data).map { .decimal($0) } ?? fallback(data, column)
        case .date, .datetime, .datetime2, .timestamp, .timestamp2:
            return data.date.map { .date($0) } ?? fallback(data, column)
        case .json:
            guard let text = data.string ?? bufferText(data) else {
                return fallback(data, column)
            }
            return jsonValue(from: text)
        case .blob, .tinyBlob, .mediumBlob, .longBlob:
            if column.characterSet == .binary {
                if var buffer = data.buffer,
                   let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    return .bytes(Data(bytes))
                }
                return fallback(data, column)
            }
            return data.string.map { .string($0) } ?? fallback(data, column)
        case .bit, .geometry:
            if var buffer = data.buffer,
               let bytes = buffer.readBytes(length: buffer.readableBytes) {
                return .bytes(Data(bytes))
            }
            return fallback(data, column)
        default:
            return data.string.map { .string($0) } ?? fallback(data, column)
        }
    }

    private static func bufferText(_ data: MySQLData) -> String? {
        guard var buffer = data.buffer else { return nil }
        return buffer.readString(length: buffer.readableBytes)
    }

    private static func fallback(
        _ data: MySQLData, _ column: MySQLProtocol.ColumnDefinition41
    ) -> DBValue {
        if let text = data.string { return .string(text) }
        return .unsupported(
            typeName: data.type.description,
            text: "(binary, \(data.buffer?.readableBytes ?? 0) bytes)")
    }

    static func jsonValue(from text: String) -> DBValue {
        DBValue.fromJSONText(text) ?? .string(text)
    }
}
