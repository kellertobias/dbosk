import DBCore
import Foundation
import Logging
import NIOSSL
import PostgresNIO

public final class PostgresDriver: DatabaseDriver, Sendable {
    public static let descriptor = DriverDescriptor(
        id: "postgres",
        displayName: "PostgreSQL",
        queryLanguage: .sql,
        defaultPort: 5432,
        supportsStreaming: true,
        supportsServerSideCancel: true
    )

    private let config: ResolvedConnectionConfig
    private let state: ConnectionActor

    public init(config: ResolvedConnectionConfig) throws {
        self.config = config
        self.state = ConnectionActor(configuration: try Self.makeConfiguration(config))
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
            // Root: schemas of the connected database.
            let rows = try await state.collect(
                """
                SELECT nspname FROM pg_catalog.pg_namespace
                WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
                ORDER BY nspname
                """)
            return rows.compactMap { row in
                guard case .string(let name) = row.first else { return nil }
                return Namespace(path: [name], kind: .schema, isExpandable: true)
            }
        case .schema:
            let schema = parent!.name
            let rows = try await state.collect(
                """
                SELECT table_name, table_type FROM information_schema.tables
                WHERE table_schema = \(schema)
                ORDER BY table_name
                """)
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
        let schema = table.path[0]
        let name = table.path[1]
        let rows = try await state.collect(
            """
            SELECT column_name, data_type FROM information_schema.columns
            WHERE table_schema = \(schema) AND table_name = \(name)
            ORDER BY ordinal_position
            """)
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
        let schema = table.path[0]
        let name = table.path[1]

        let indexRows = try await state.collect(
            """
            SELECT i.relname,
                   ix.indisunique,
                   ix.indisprimary,
                   am.amname,
                   array_to_string(array_agg(
                       coalesce(a.attname, '(expression)') ORDER BY k.ordinality
                   ), '\u{1F}')
            FROM pg_catalog.pg_index ix
            JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
            JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_catalog.pg_am am ON am.oid = i.relam
            CROSS JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ordinality)
            LEFT JOIN pg_catalog.pg_attribute a
                ON a.attrelid = t.oid AND a.attnum = k.attnum AND k.attnum > 0
            WHERE n.nspname = \(schema) AND t.relname = \(name)
            GROUP BY i.relname, ix.indisunique, ix.indisprimary, am.amname
            ORDER BY ix.indisprimary DESC, i.relname
            """)
        let indexes: [IndexInfo] = indexRows.compactMap { row in
            guard case .string(let indexName) = row[safe: 0],
                  case .bool(let unique) = row[safe: 1],
                  case .bool(let primary) = row[safe: 2],
                  case .string(let method) = row[safe: 3],
                  case .string(let columnList) = row[safe: 4]
            else { return nil }
            return IndexInfo(
                name: indexName,
                columns: columnList.components(separatedBy: "\u{1F}"),
                isUnique: unique,
                isPrimary: primary,
                method: method)
        }
        let primaryColumns = Set(indexes.filter(\.isPrimary).flatMap(\.columns))

        let columnRows = try await state.collect(
            """
            SELECT column_name, data_type, is_nullable, column_default
            FROM information_schema.columns
            WHERE table_schema = \(schema) AND table_name = \(name)
            ORDER BY ordinal_position
            """)
        let columns: [ColumnDetail] = columnRows.compactMap { row in
            guard case .string(let column) = row[safe: 0],
                  case .string(let type) = row[safe: 1],
                  case .string(let nullable) = row[safe: 2]
            else { return nil }
            var defaultValue: String?
            if case .string(let text) = row[safe: 3] { defaultValue = text }
            return ColumnDetail(
                name: column,
                dbTypeName: type,
                isNullable: nullable == "YES",
                defaultValue: defaultValue,
                isPrimaryKey: primaryColumns.contains(column))
        }
        return TableStructure(columns: columns, indexes: indexes)
    }

    public func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        guard case .sql(let sql) = query else {
            throw DBError(kind: .unsupported, message: "PostgreSQL driver only accepts SQL")
        }
        return try await state.execute(sql: sql, pageSize: pageSize)
    }

    // MARK: - Configuration

    private static func makeConfiguration(
        _ config: ResolvedConnectionConfig
    ) throws -> PostgresConnection.Configuration {
        var resolved = config
        if let uri = config.uri {
            resolved = try Self.merge(uri: uri, into: config)
        }

        let tls: PostgresConnection.Configuration.TLS
        switch resolved.tls {
        case .disabled:
            tls = .disable
        case .preferred:
            tls = .prefer(try NIOSSLContext(configuration: .clientDefault))
        case .required:
            tls = .require(try NIOSSLContext(configuration: .clientDefault))
        }

        return PostgresConnection.Configuration(
            host: resolved.host ?? "localhost",
            port: resolved.port ?? 5432,
            username: resolved.user ?? "postgres",
            password: resolved.password,
            database: resolved.database,
            tls: tls
        )
    }

    private static func merge(
        uri: String, into config: ResolvedConnectionConfig
    ) throws -> ResolvedConnectionConfig {
        guard let components = URLComponents(string: uri),
              components.scheme == "postgres" || components.scheme == "postgresql"
        else {
            throw DBError(kind: .connectionFailed, message: "Invalid PostgreSQL URI")
        }
        var merged = config
        if let host = components.host { merged.host = host }
        if let port = components.port { merged.port = port }
        if let user = components.user { merged.user = user }
        if let password = components.password { merged.password = password }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty { merged.database = path }
        if components.queryItems?.contains(where: {
            $0.name == "sslmode" && ($0.value == "disable")
        }) == true {
            merged.tls = .disabled
        }
        return merged
    }
}

extension Array where Element == DBValue {
    subscript(safe index: Int) -> DBValue? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Connection actor

/// Serializes access to the underlying PostgresConnection.
private actor ConnectionActor {
    private let configuration: PostgresConnection.Configuration
    private let logger = Logger(label: "dbosk.postgres")
    private var connection: PostgresConnection?
    private static let connectionID = ManagedAtomicCounter()

    init(configuration: PostgresConnection.Configuration) {
        self.configuration = configuration
    }

    func connect() async throws {
        guard connection == nil else { return }
        do {
            connection = try await PostgresConnection.connect(
                configuration: configuration,
                id: Self.connectionID.next(),
                logger: logger
            )
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not connect to PostgreSQL",
                underlying: String(reflecting: error))
        }
    }

    func disconnect() async {
        try? await connection?.close()
        connection = nil
    }

    private func requireConnection() throws -> PostgresConnection {
        guard let connection else {
            throw DBError(kind: .connectionFailed, message: "Not connected")
        }
        return connection
    }

    /// Small internal helper for metadata queries: buffers all rows.
    func collect(_ query: PostgresQuery) async throws -> [[DBValue]] {
        let connection = try requireConnection()
        let rows = try await connection.query(query, logger: logger)
        var result: [[DBValue]] = []
        for try await row in rows {
            result.append(row.map { PostgresValueMapper.value(for: $0) })
        }
        return result
    }

    func execute(sql: String, pageSize: Int) async throws -> QueryExecution {
        let connection = try requireConnection()
        let logger = self.logger

        let rows: PostgresRowSequence
        do {
            rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: Self.friendlyMessage(for: error),
                underlying: String(reflecting: error))
        }

        // Column metadata is only known once the first row arrives, so peek it here.
        var iterator = rows.makeAsyncIterator()
        let firstRow: PostgresRow?
        do {
            firstRow = try await iterator.next()
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: Self.friendlyMessage(for: error),
                underlying: String(reflecting: error))
        }

        let columns: [ColumnMeta] = (firstRow?.map {
            ColumnMeta(name: $0.columnName, dbTypeName: String(describing: $0.dataType))
        }) ?? []

        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
            .makeStream()

        // PostgresNIO cancels the running query when the consuming task is
        // cancelled, which is our server-side cancel path.
        let producer = Task {
            var buffer: [ResultRow] = []
            var index = 0
            do {
                if let firstRow {
                    buffer.append(ResultRow(
                        id: index, values: firstRow.map { PostgresValueMapper.value(for: $0) }))
                    index += 1
                }
                var next = try await iterator.next()
                while let row = next {
                    buffer.append(ResultRow(
                        id: index, values: row.map { PostgresValueMapper.value(for: $0) }))
                    index += 1
                    if buffer.count >= pageSize {
                        continuation.yield(QueryResultChunk(rows: buffer, isFinal: false))
                        buffer = []
                    }
                    try Task.checkCancellation()
                    next = try await iterator.next()
                }
                continuation.yield(QueryResultChunk(rows: buffer, isFinal: true))
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
        continuation.onTermination = { _ in producer.cancel() }

        return QueryExecution(
            columns: columns,
            chunks: stream,
            cancel: { producer.cancel() }
        )
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let psqlError = error as? PSQLError, let serverInfo = psqlError.serverInfo,
           let message = serverInfo[.message] {
            return message
        }
        return "Query failed"
    }
}

// MARK: - Value mapping

enum PostgresValueMapper {
    static func value(for cell: PostgresCell) -> DBValue {
        guard cell.bytes != nil else { return .null }
        do {
            switch cell.dataType {
            case .bool:
                return .bool(try cell.decode(Bool.self))
            case .int2:
                return .int(Int64(try cell.decode(Int16.self)))
            case .int4:
                return .int(Int64(try cell.decode(Int32.self)))
            case .int8:
                return .int(try cell.decode(Int64.self))
            case .float4:
                return .double(Double(try cell.decode(Float.self)))
            case .float8:
                return .double(try cell.decode(Double.self))
            case .numeric:
                return .decimal("\(try cell.decode(Decimal.self))")
            case .uuid:
                return .uuid(try cell.decode(UUID.self))
            case .date, .timestamp, .timestamptz:
                return .date(try cell.decode(Date.self))
            case .bytea:
                let buffer = try cell.decode(ByteBuffer.self)
                return .bytes(Data(buffer.readableBytesView))
            case .json, .jsonb:
                let text = try cell.decode(String.self)
                return jsonValue(from: text)
            case .text, .varchar, .bpchar, .name:
                return .string(try cell.decode(String.self))
            default:
                // Try text; most types have a textual representation.
                if let text = try? cell.decode(String.self) {
                    return .string(text)
                }
                return .unsupported(
                    typeName: String(describing: cell.dataType),
                    text: "(binary, \(cell.bytes?.readableBytes ?? 0) bytes)")
            }
        } catch {
            return .unsupported(
                typeName: String(describing: cell.dataType),
                text: "(decode failed)")
        }
    }

    static func jsonValue(from text: String) -> DBValue {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return .string(text) }
        return dbValue(fromJSON: object)
    }

    static func dbValue(fromJSON object: Any) -> DBValue {
        switch object {
        case is NSNull: return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .double(number.doubleValue)
            }
            return .int(number.int64Value)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map { dbValue(fromJSON: $0) })
        case let dict as [String: Any]:
            return .document(dict.mapValues { dbValue(fromJSON: $0) })
        default: return .string(String(describing: object))
        }
    }
}

/// Monotonic connection ids for PostgresNIO logging.
private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
