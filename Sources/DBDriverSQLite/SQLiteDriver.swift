import DBCore
import Foundation
import GRDB

public final class SQLiteDriver: DatabaseDriver, Sendable {
    public static let descriptor = DriverDescriptor(
        id: "sqlite",
        displayName: "SQLite",
        queryLanguage: .sql,
        defaultPort: nil,
        supportsStreaming: true,
        supportsServerSideCancel: true
    )

    private let filePath: String
    private let state: ConnectionActor

    public init(config: ResolvedConnectionConfig) throws {
        guard let filePath = config.filePath, !filePath.isEmpty else {
            throw DBError(kind: .connectionFailed, message: "No SQLite file selected")
        }
        self.filePath = (filePath as NSString).expandingTildeInPath
        self.state = ConnectionActor(path: self.filePath)
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
            // Single-file database: root is one "main" node.
            let name = (filePath as NSString).lastPathComponent
            return [Namespace(path: [name], kind: .database, isExpandable: true)]
        case .database:
            let rows = try await state.collect(
                """
                SELECT name, type FROM sqlite_master
                WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
            return rows.compactMap { row in
                guard case .string(let name) = row.first,
                      case .string(let type) = row.dropFirst().first
                else { return nil }
                return Namespace(
                    path: [name],  // single-level: table name is the full path
                    kind: .table(type == "view" ? .view : .table),
                    isExpandable: false)
            }
        default:
            return []
        }
    }

    public func listColumns(of table: Namespace) async throws -> [ColumnMeta] {
        guard let name = table.path.last else { return [] }
        let rows = try await state.collect(
            "SELECT name, type FROM pragma_table_info(\(quotedLiteral(name)))")
        return rows.compactMap { row in
            guard case .string(let column) = row.first else { return nil }
            let type: String
            if case .string(let typeName) = row.dropFirst().first, !typeName.isEmpty {
                type = typeName
            } else {
                type = "any"
            }
            return ColumnMeta(name: column, dbTypeName: type)
        }
    }

    public func describeTable(_ table: Namespace) async throws -> TableStructure {
        guard let name = table.path.last else {
            return TableStructure(columns: [], indexes: [])
        }
        let literal = quotedLiteral(name)

        let columnRows = try await state.collect(
            "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(\(literal))")
        let columns: [ColumnDetail] = columnRows.compactMap { row in
            guard case .string(let column) = row[safe: 0] else { return nil }
            var type = "any"
            if case .string(let typeName) = row[safe: 1], !typeName.isEmpty {
                type = typeName
            }
            var notNull = false
            if case .int(let flag) = row[safe: 2] { notNull = flag != 0 }
            var defaultValue: String?
            if case .string(let text) = row[safe: 3] { defaultValue = text }
            var isPrimary = false
            if case .int(let pk) = row[safe: 4] { isPrimary = pk > 0 }
            return ColumnDetail(
                name: column,
                dbTypeName: type,
                isNullable: !notNull,
                defaultValue: defaultValue,
                isPrimaryKey: isPrimary)
        }

        // origin: "c" = CREATE INDEX, "u" = UNIQUE constraint, "pk" = primary key.
        let indexRows = try await state.collect(
            "SELECT name, \"unique\", origin FROM pragma_index_list(\(literal))")
        // Qualified: GRDB exports its own IndexInfo.
        var indexes: [DBCore.IndexInfo] = []
        for row in indexRows {
            guard case .string(let indexName) = row[safe: 0] else { continue }
            var unique = false
            if case .int(let flag) = row[safe: 1] { unique = flag != 0 }
            var origin = "c"
            if case .string(let text) = row[safe: 2] { origin = text }
            let columnRows = try await state.collect(
                """
                SELECT coalesce(name, '(expression)')
                FROM pragma_index_info(\(quotedLiteral(indexName))) ORDER BY seqno
                """)
            let indexColumns: [String] = columnRows.compactMap { row in
                guard case .string(let column) = row.first else { return nil }
                return column
            }
            indexes.append(IndexInfo(
                name: indexName,
                columns: indexColumns,
                isUnique: unique,
                isPrimary: origin == "pk"))
        }
        indexes.sort { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }

        // INTEGER PRIMARY KEY (rowid alias) has no pragma_index_list entry;
        // surface it as a synthetic primary index so the UI still shows the key.
        let primaryColumns = columns.filter(\.isPrimaryKey).map(\.name)
        if !primaryColumns.isEmpty, !indexes.contains(where: { $0.isPrimary }) {
            indexes.insert(
                DBCore.IndexInfo(
                    name: "PRIMARY KEY",
                    columns: primaryColumns,
                    isUnique: true,
                    isPrimary: true),
                at: 0)
        }
        return TableStructure(columns: columns, indexes: indexes)
    }

    public func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        guard case .sql(let sql) = query else {
            throw DBError(kind: .unsupported, message: "SQLite driver only accepts SQL")
        }
        return try await state.execute(sql: sql, pageSize: pageSize)
    }

    private func quotedLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

extension Array where Element == DBValue {
    subscript(safe index: Int) -> DBValue? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Connection actor

private actor ConnectionActor {
    private let path: String
    private var queue: DatabaseQueue?

    init(path: String) {
        self.path = path
    }

    func connect() async throws {
        guard queue == nil else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            throw DBError(
                kind: .connectionFailed, message: "File not found: \(path)")
        }
        do {
            queue = try DatabaseQueue(path: path)
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not open SQLite database",
                underlying: String(reflecting: error))
        }
    }

    func disconnect() {
        queue = nil
    }

    private func requireQueue() throws -> DatabaseQueue {
        guard let queue else {
            throw DBError(kind: .connectionFailed, message: "Not connected")
        }
        return queue
    }

    func collect(_ sql: String) async throws -> [[DBValue]] {
        let queue = try requireQueue()
        do {
            return try await queue.read { db in
                var result: [[DBValue]] = []
                let rows = try Row.fetchCursor(db, sql: sql)
                while let row = try rows.next() {
                    result.append(SQLiteValueMapper.values(for: row))
                }
                return result
            }
        } catch {
            throw Self.queryError(error)
        }
    }

    func execute(sql: String, pageSize: Int) async throws -> QueryExecution {
        let queue = try requireQueue()

        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
            .makeStream()
        let columnsBox = ColumnsBox()

        let producer = Task {
            do {
                try await queue.writeWithoutTransaction { db in
                    let statement = try db.makeStatement(sql: sql)
                    columnsBox.set(statement.columnNames.map {
                        ColumnMeta(name: $0, dbTypeName: "any")
                    })
                    var buffer: [ResultRow] = []
                    var index = 0
                    let rows = try Row.fetchCursor(statement)
                    while let row = try rows.next() {
                        buffer.append(ResultRow(
                            id: index, values: SQLiteValueMapper.values(for: row)))
                        index += 1
                        if buffer.count >= pageSize {
                            continuation.yield(QueryResultChunk(rows: buffer, isFinal: false))
                            buffer = []
                        }
                        try Task.checkCancellation()
                    }
                    continuation.yield(QueryResultChunk(
                        rows: buffer,
                        isFinal: true,
                        affectedCount: db.changesCount > 0 ? db.changesCount : nil))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: DBError(kind: .cancelled, message: "Query cancelled"))
            } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
                continuation.finish(throwing: DBError(kind: .cancelled, message: "Query cancelled"))
            } catch {
                continuation.finish(throwing: Self.queryError(error))
            }
            // Unblock execute() if preparation failed before columns were set.
            columnsBox.set([])
        }

        let cancel: @Sendable () async -> Void = {
            producer.cancel()
            // sqlite3_interrupt stops a statement running on another thread.
            queue.interrupt()
        }
        continuation.onTermination = { _ in producer.cancel() }

        // Wait until the statement is prepared so columns are known.
        let columns = await columnsBox.wait()
        return QueryExecution(columns: columns, chunks: stream, cancel: cancel)
    }

    private static func queryError(_ error: Error) -> DBError {
        if let dbError = error as? DBError { return dbError }
        if let databaseError = error as? DatabaseError {
            return DBError(
                kind: .queryFailed,
                message: databaseError.message ?? "Query failed",
                underlying: String(reflecting: error))
        }
        return DBError(
            kind: .queryFailed, message: "Query failed",
            underlying: String(reflecting: error))
    }
}

/// Hands the column list from the producer task to `execute`'s caller.
private final class ColumnsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var columns: [ColumnMeta]?
    private var waiters: [CheckedContinuation<[ColumnMeta], Never>] = []

    /// First call wins; later calls are ignored.
    func set(_ value: [ColumnMeta]) {
        lock.lock()
        guard columns == nil else {
            lock.unlock()
            return
        }
        columns = value
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: value) }
    }

    func wait() async -> [ColumnMeta] {
        await withCheckedContinuation { continuation in
            register(continuation)
        }
    }

    private func register(_ continuation: CheckedContinuation<[ColumnMeta], Never>) {
        lock.lock()
        if let columns {
            lock.unlock()
            continuation.resume(returning: columns)
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }
}

// MARK: - Value mapping

enum SQLiteValueMapper {
    static func values(for row: Row) -> [DBValue] {
        (0..<row.count).map { index in
            value(for: row[index] as DatabaseValueConvertible?)
        }
    }

    static func value(for raw: DatabaseValueConvertible?) -> DBValue {
        guard let raw else { return .null }
        switch raw.databaseValue.storage {
        case .null:
            return .null
        case .int64(let int):
            return .int(int)
        case .double(let double):
            return .double(double)
        case .string(let string):
            return .string(string)
        case .blob(let data):
            return .bytes(data)
        }
    }
}
