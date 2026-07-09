import Foundation

// MARK: - Descriptor & capabilities

public struct DriverDescriptor: Sendable {
    public enum QueryLanguage: Sendable { case sql, mongo, redis, partiql }

    public let id: String
    public let displayName: String
    public let queryLanguage: QueryLanguage
    public let defaultPort: Int?
    public let supportsStreaming: Bool
    public let supportsServerSideCancel: Bool
    /// Character wrapping identifiers in generated SQL ("\"" for standard SQL,
    /// "`" for MySQL). Empty for non-SQL drivers.
    public let identifierQuote: String

    public init(
        id: String,
        displayName: String,
        queryLanguage: QueryLanguage,
        defaultPort: Int?,
        supportsStreaming: Bool,
        supportsServerSideCancel: Bool,
        identifierQuote: String = "\""
    ) {
        self.id = id
        self.displayName = displayName
        self.queryLanguage = queryLanguage
        self.defaultPort = defaultPort
        self.supportsStreaming = supportsStreaming
        self.supportsServerSideCancel = supportsServerSideCancel
        self.identifierQuote = identifierQuote
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

    public init(
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        password: String? = nil,
        database: String? = nil,
        uri: String? = nil,
        filePath: String? = nil,
        tls: TLSMode = .preferred
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.uri = uri
        self.filePath = filePath
        self.tls = tls
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

    public var id: String { path.joined(separator: "\u{1F}") + "|\(kind)" }
    public var name: String { path.last ?? "" }

    public init(path: [String], kind: Kind, isExpandable: Bool) {
        self.path = path
        self.kind = kind
        self.isExpandable = isExpandable
    }
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

// MARK: - Errors

public struct DBError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable {
        case connectionFailed
        case queryFailed
        case cancelled
        case unsupported
        case credentialResolutionFailed
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
}
