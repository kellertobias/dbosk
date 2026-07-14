import Foundation

// MARK: - Descriptor & capabilities

public struct DriverDescriptor: Sendable {
    public enum QueryLanguage: Sendable { case sql, mongo, redis, partiql }

    /// Whether the engine can report a query execution plan, and whether it
    /// additionally supports an "analyze" variant that runs the query for
    /// real row counts and timings.
    public enum ExplainSupport: Sendable, Equatable {
        case none, plan, planAndAnalyze
    }

    /// What kind of namespace unqualified SQL names resolve against, for
    /// engines where the session can switch it (Postgres `SET search_path`,
    /// MySQL `USE`). Nil when the engine has no such notion (SQLite) or the
    /// query language isn't SQL.
    public enum ActiveNamespaceKind: Sendable, Equatable {
        case database, schema

        public var displayName: String {
            switch self {
            case .database: return "Database"
            case .schema: return "Schema"
            }
        }
    }

    public let id: String
    public let displayName: String
    public let queryLanguage: QueryLanguage
    public let defaultPort: Int?
    public let supportsStreaming: Bool
    public let supportsServerSideCancel: Bool
    /// Character wrapping identifiers in generated SQL ("\"" for standard SQL,
    /// "`" for MySQL). Empty for non-SQL drivers.
    public let identifierQuote: String
    /// SQL dialect for generated DML/DDL and value literals. Nil for drivers
    /// without structured write support.
    public let sqlDialect: SQLDialect?
    /// Staged row editing (insert/update/delete) in Table mode.
    public let supportsTableEditing: Bool
    /// Structured DDL (create/alter/drop table, create/drop index).
    public let supportsDDL: Bool
    /// Query-plan inspection ("Explain" in the query toolbar).
    public let explainSupport: ExplainSupport
    /// Session-switchable target for unqualified SQL names, when supported.
    public let activeNamespaceKind: ActiveNamespaceKind?
    /// Whether the connection is a TCP host:port the app may route through an
    /// SSH tunnel. False for HTTP-API drivers whose "host" is a base URL.
    public let supportsSSHTunnel: Bool
    /// Whether generated SQL may qualify tables with the root `.database`
    /// path component (`"db"."table"`). False when that component is only an
    /// out-of-band routing label the backing engine cannot resolve (Metabase);
    /// such tables are addressed by the remaining path and the driver routes
    /// the query to the right database itself.
    public let supportsDatabaseQualifiedSQL: Bool
    /// Whether a fresh connection starts with every root namespace hidden so
    /// the user explicitly picks what to show (drivers that expose an
    /// unbounded, org-wide set of databases).
    public let rootNamespacesDefaultHidden: Bool
    /// Whether the app should hand table browsing to the driver as a
    /// `.tableBrowse` query instead of generating `SELECT …` itself. True for
    /// drivers whose databases span multiple SQL dialects (Metabase), where
    /// only the driver knows the target engine's quoting and paging syntax.
    public let buildsTableBrowseInDriver: Bool

    public init(
        id: String,
        displayName: String,
        queryLanguage: QueryLanguage,
        defaultPort: Int?,
        supportsStreaming: Bool,
        supportsServerSideCancel: Bool,
        identifierQuote: String = "\"",
        sqlDialect: SQLDialect? = nil,
        supportsTableEditing: Bool = false,
        supportsDDL: Bool = false,
        explainSupport: ExplainSupport = .none,
        activeNamespaceKind: ActiveNamespaceKind? = nil,
        supportsSSHTunnel: Bool = true,
        supportsDatabaseQualifiedSQL: Bool = true,
        rootNamespacesDefaultHidden: Bool = false,
        buildsTableBrowseInDriver: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.queryLanguage = queryLanguage
        self.defaultPort = defaultPort
        self.supportsStreaming = supportsStreaming
        self.supportsServerSideCancel = supportsServerSideCancel
        self.identifierQuote = identifierQuote
        self.sqlDialect = sqlDialect
        self.supportsTableEditing = supportsTableEditing
        self.supportsDDL = supportsDDL
        self.explainSupport = explainSupport
        self.activeNamespaceKind = activeNamespaceKind
        self.supportsSSHTunnel = supportsSSHTunnel
        self.supportsDatabaseQualifiedSQL = supportsDatabaseQualifiedSQL
        self.rootNamespacesDefaultHidden = rootNamespacesDefaultHidden
        self.buildsTableBrowseInDriver = buildsTableBrowseInDriver
    }

    /// Quotes an identifier for this driver's SQL dialect.
    public func quoted(_ identifier: String) -> String {
        guard !identifierQuote.isEmpty else { return identifier }
        let escaped = identifier.replacingOccurrences(
            of: identifierQuote, with: identifierQuote + identifierQuote)
        return identifierQuote + escaped + identifierQuote
    }
}

// MARK: - Connection config (post credential resolution, secrets in memory only)

public struct ResolvedConnectionConfig: Sendable {
    public enum TLSMode: String, Sendable, Codable, CaseIterable {
        case disabled, preferred, required
    }

    public var host: String?
    public var port: Int?
    public var user: String?
    public var password: String?
    public var database: String?
    /// Full connection URI; when present it wins over the discrete fields.
    public var uri: String?
    /// For file-based databases (SQLite).
    public var filePath: String?
    public var tls: TLSMode
    /// Secret-free note about how credentials were resolved (e.g. which keys
    /// an AWS secret contained), appended to connection errors for debugging.
    public var credentialDiagnostics: String?

    public init(
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        password: String? = nil,
        database: String? = nil,
        uri: String? = nil,
        filePath: String? = nil,
        tls: TLSMode = .preferred,
        credentialDiagnostics: String? = nil
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.uri = uri
        self.filePath = filePath
        self.tls = tls
        self.credentialDiagnostics = credentialDiagnostics
    }
}

// MARK: - Namespaces (sidebar tree)

public enum TableKind: String, Sendable, Hashable {
    case table, view, collection, systemTable
}

public struct Namespace: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case database
        case schema
        case table(TableKind)
    }

    /// Stable path from root, e.g. ["mydb", "public", "users"].
    public let path: [String]
    public let kind: Kind
    /// Whether children may exist (drives lazy disclosure in the sidebar).
    public let isExpandable: Bool
    /// `path` joined with the same separator `ConnectionMetadata.key(for:)`
    /// uses, so metadata lookups need no re-join. Precomputed: identity is
    /// hot in sidebar rendering with thousands of tables.
    public let pathKey: String
    public let id: String

    public var name: String { path.last ?? "" }

    public init(path: [String], kind: Kind, isExpandable: Bool) {
        self.path = path
        self.kind = kind
        self.isExpandable = isExpandable
        self.pathKey = path.joined(separator: "\u{1F}")
        self.id = pathKey + "|\(kind)"
    }

    // `id` fully determines path and kind; comparing/hashing one string
    // beats element-wise array comparison in Set/Dictionary hot paths.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Namespace.Kind: CustomStringConvertible {
    public var description: String {
        switch self {
        case .database: return "database"
        case .schema: return "schema"
        case .table(let kind): return kind.rawValue
        }
    }
}

// MARK: - Query & results

public enum DriverQuery: Sendable {
    case sql(String)
    /// v1 Mongo model: collection + operation + JSON filter/pipeline document.
    case mongo(collection: String, operation: MongoOperation, body: String)
    /// Structured "browse one table" request. Drivers that advertise
    /// `buildsTableBrowseInDriver` receive this instead of generated SQL, so a
    /// driver spanning heterogeneous engines (Metabase) can emit SQL in the
    /// dialect of the table's own database rather than a single fixed dialect.
    case tableBrowse(TableBrowseRequest)
}

/// A read-only page over one table, addressed by its sidebar namespace path.
public struct TableBrowseRequest: Sendable {
    /// Namespace path of the table, e.g. ["db", "schema", "users"].
    public let path: [String]
    /// Columns to project, in table order; empty means all columns.
    public let columns: [String]
    /// Optional raw WHERE predicate typed by the user, sans the `WHERE` keyword.
    public let filter: String?
    public let limit: Int
    public let offset: Int

    public init(
        path: [String], columns: [String] = [],
        filter: String? = nil, limit: Int, offset: Int
    ) {
        self.path = path
        self.columns = columns
        self.filter = filter
        self.limit = limit
        self.offset = offset
    }
}

public enum MongoOperation: String, Sendable, CaseIterable {
    case find, aggregate, count
}

public struct ColumnMeta: Sendable, Hashable {
    public let name: String
    public let dbTypeName: String

    public init(name: String, dbTypeName: String) {
        self.name = name
        self.dbTypeName = dbTypeName
    }
}

// MARK: - Table structure

/// Full column description for the structure view; `ColumnMeta` stays the
/// lightweight name+type pair used by result grids and column pickers.
public struct ColumnDetail: Sendable, Hashable, Identifiable {
    public let name: String
    public let dbTypeName: String
    public let isNullable: Bool
    public let defaultValue: String?
    public let isPrimaryKey: Bool

    public var id: String { name }

    public init(
        name: String,
        dbTypeName: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false
    ) {
        self.name = name
        self.dbTypeName = dbTypeName
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
    }
}

public struct IndexInfo: Sendable, Hashable, Identifiable {
    public let name: String
    /// Indexed columns/keys in index order.
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimary: Bool
    /// Index method/type when the engine reports one (btree, hash, FULLTEXT…).
    public let method: String?

    public var id: String { name }

    public init(
        name: String,
        columns: [String],
        isUnique: Bool,
        isPrimary: Bool = false,
        method: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
    }
}

public struct TableStructure: Sendable, Hashable {
    public let columns: [ColumnDetail]
    public let indexes: [IndexInfo]

    public init(columns: [ColumnDetail], indexes: [IndexInfo]) {
        self.columns = columns
        self.indexes = indexes
    }
}

public struct ResultRow: Sendable, Identifiable {
    /// 0-based index within the result set.
    public let id: Int
    public let values: [DBValue]

    public init(id: Int, values: [DBValue]) {
        self.id = id
        self.values = values
    }
}

public struct QueryResultChunk: Sendable {
    public let rows: [ResultRow]
    public let isFinal: Bool
    /// Affected-row count for DML statements, when the server reports one.
    public let affectedCount: Int?

    public init(rows: [ResultRow], isFinal: Bool, affectedCount: Int? = nil) {
        self.rows = rows
        self.isFinal = isFinal
        self.affectedCount = affectedCount
    }
}

public struct QueryExecution: Sendable {
    public let columns: [ColumnMeta]
    /// Rows arrive in `pageSize`-bounded chunks; the stream finishes when the
    /// result set is exhausted, throws on error, and stops early on cancel.
    public let chunks: AsyncThrowingStream<QueryResultChunk, Error>
    /// Cancels the running query. Also invoked via Task cancellation of the consumer.
    public let cancel: @Sendable () async -> Void

    public init(
        columns: [ColumnMeta],
        chunks: AsyncThrowingStream<QueryResultChunk, Error>,
        cancel: @escaping @Sendable () async -> Void
    ) {
        self.columns = columns
        self.chunks = chunks
        self.cancel = cancel
    }
}

// MARK: - Batch execution (staged edits, DDL)

public struct BatchStatementResult: Sendable {
    /// Affected-row count when the server reports one; nil for DDL or drivers
    /// that don't surface counts (Postgres).
    public let affectedCount: Int?

    public init(affectedCount: Int?) {
        self.affectedCount = affectedCount
    }
}

/// Failure inside `executeBatch`: identifies the failing statement so the UI
/// can point at the offending change.
public struct BatchError: Error, Sendable, CustomStringConvertible {
    /// Index into the submitted statements; `statements.count` means COMMIT failed.
    public let statementIndex: Int
    public let statement: String
    public let underlying: DBError
    /// Whether the transaction was rolled back (best effort for BEGIN/COMMIT drivers).
    public let rolledBack: Bool

    public init(statementIndex: Int, statement: String, underlying: DBError, rolledBack: Bool) {
        self.statementIndex = statementIndex
        self.statement = statement
        self.underlying = underlying
        self.rolledBack = rolledBack
    }

    public var description: String {
        "Statement \(statementIndex + 1) failed: \(underlying.description)"
    }
}

// MARK: - Errors

public struct DBError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable {
        case connectionFailed
        case queryFailed
        case cancelled
        case unsupported
        case credentialResolutionFailed
        /// A previously valid auth session (e.g. a Metabase SSO session token)
        /// was rejected by the server. The UI reacts by prompting the user to
        /// sign in again rather than showing a generic connection error.
        case authenticationExpired
    }

    public let kind: Kind
    public let message: String
    public let underlying: String?

    public init(kind: Kind, message: String, underlying: String? = nil) {
        self.kind = kind
        self.message = message
        self.underlying = underlying
    }

    public var description: String {
        if let underlying { return "\(message) (\(underlying))" }
        return message
    }
}

// MARK: - Driver protocol

public protocol DatabaseDriver: Sendable {
    static var descriptor: DriverDescriptor { get }

    init(config: ResolvedConnectionConfig) throws

    func connect() async throws
    func disconnect() async

    /// Lists children of `parent` (nil = root). Lazy: called as tree nodes expand.
    func listNamespaces(parent: Namespace?) async throws -> [Namespace]

    /// Lists the columns of a table/collection without running a query.
    func listColumns(of table: Namespace) async throws -> [ColumnMeta]

    /// Full structure of a table: detailed columns plus indexes.
    /// Defaults to `listColumns` with no index information.
    func describeTable(_ table: Namespace) async throws -> TableStructure

    /// Executes a query, streaming results in `pageSize`-bounded chunks.
    /// Implementations must honor Task cancellation and perform a driver-level
    /// cancel (server-side where supported) via `QueryExecution.cancel`.
    func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution

    /// Executes statements atomically: all succeed or all roll back.
    /// Defaults to BEGIN/COMMIT through `execute` (safe for single-connection
    /// SQL drivers); SQLite overrides with a GRDB-native transaction.
    func executeBatch(_ statements: [String]) async throws -> [BatchStatementResult]

    /// Reports the engine's execution plan for `query`. `analyze` runs the
    /// query for real row counts and timings (only when the descriptor
    /// advertises `.planAndAnalyze`). Defaults to wrapping SQL in the
    /// dialect's EXPLAIN statement through `execute`; MongoDB overrides with
    /// the `explain` database command.
    func explain(_ query: DriverQuery, analyze: Bool) async throws -> ExplainPlan

    /// Points unqualified SQL names at `name` for the rest of the session
    /// (`SET search_path` / `USE`); nil restores the connection default.
    /// Only meaningful when the descriptor advertises `activeNamespaceKind`.
    /// Defaults to running the dialect statement through `execute`.
    func setActiveNamespace(_ name: String?) async throws
}

extension DatabaseDriver {
    public func describeTable(_ table: Namespace) async throws -> TableStructure {
        let columns = try await listColumns(of: table)
        return TableStructure(
            columns: columns.map {
                ColumnDetail(name: $0.name, dbTypeName: $0.dbTypeName)
            },
            indexes: [])
    }

    public func executeBatch(_ statements: [String]) async throws -> [BatchStatementResult] {
        guard Self.descriptor.queryLanguage == .sql else {
            throw DBError(
                kind: .unsupported,
                message: "\(Self.descriptor.displayName) does not support batch execution")
        }

        /// Runs one statement to completion, returning its affected count.
        @Sendable func run(_ sql: String) async throws -> Int? {
            let execution = try await execute(.sql(sql), pageSize: 1000)
            var affected: Int?
            for try await chunk in execution.chunks {
                if let count = chunk.affectedCount { affected = count }
            }
            return affected
        }

        func fail(at index: Int, statement: String, error: Error) async -> BatchError {
            // Not `try?`: it flattens the Int? result, making a successful
            // rollback with no affected count look like a failure.
            var rolledBack = false
            do {
                _ = try await run("ROLLBACK")
                rolledBack = true
            } catch {}
            let dbError = error as? DBError
                ?? DBError(kind: .queryFailed, message: String(describing: error))
            return BatchError(
                statementIndex: index, statement: statement,
                underlying: dbError, rolledBack: rolledBack)
        }

        _ = try await run("BEGIN")
        var results: [BatchStatementResult] = []
        for (index, statement) in statements.enumerated() {
            do {
                results.append(BatchStatementResult(affectedCount: try await run(statement)))
            } catch {
                throw await fail(at: index, statement: statement, error: error)
            }
        }
        do {
            _ = try await run("COMMIT")
        } catch {
            throw await fail(at: statements.count, statement: "COMMIT", error: error)
        }
        return results
    }
}
