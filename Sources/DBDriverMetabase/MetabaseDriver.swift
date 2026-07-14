import DBCore
import Foundation

/// Read-only driver that talks to a Metabase instance over its REST API and
/// exposes every database Metabase itself has access to.
///
/// Config mapping (no dedicated HTTP fields exist on the profile):
/// - `config.host` carries the Metabase base URL, e.g. "https://metabase.example.com"
///   (a bare host is normalized to https).
/// - `config.password` carries the Metabase session token, sent as the
///   `X-Metabase-Session` header. The token is obtained by the app's SSO
///   login flow and stored in the Keychain like any other password.
///
/// A rejected session (HTTP 401) surfaces as `DBError(kind: .authenticationExpired)`
/// so the UI can prompt for a fresh SSO login instead of showing a generic error.
public actor MetabaseDriver: DatabaseDriver {
    public static let descriptor = DriverDescriptor(
        id: "metabase",
        displayName: "Metabase",
        queryLanguage: .sql,
        defaultPort: nil,
        supportsStreaming: false,
        supportsServerSideCancel: false,
        identifierQuote: "\"",
        sqlDialect: nil,
        supportsTableEditing: false,
        supportsDDL: false,
        explainSupport: .none,
        // Selects which Metabase-exposed database native queries run against.
        // Unlike SQL drivers this is driver-local state, not a session statement.
        activeNamespaceKind: .database,
        supportsSSHTunnel: false,
        supportsDatabaseQualifiedSQL: false,
        rootNamespacesDefaultHidden: true,
        buildsTableBrowseInDriver: true
    )

    /// Qualified table lookup key; schema-less tables key on an empty schema.
    private struct TableKey: Hashable {
        let schema: String
        let name: String
    }

    /// Indexed view over one `/api/database/:id/metadata` payload, precomputed
    /// once per database so sidebar expands and column loads stay O(1)-ish.
    private struct CachedMetadata {
        /// Tables grouped by schema ("" for nil/empty), values pre-sorted by name.
        let tablesBySchema: [String: [MetabaseTable]]
        /// (schema ?? "", name) → table, for qualified `listColumns` paths.
        let tableByKey: [TableKey: MetabaseTable]
        /// Name-only lookup for unqualified paths; the schema-order first match wins.
        let tableByName: [String: MetabaseTable]

        init(tables: [MetabaseTable]) {
            let grouped = Dictionary(grouping: tables) { $0.schema ?? "" }
                .mapValues { $0.sorted { $0.name < $1.name } }
            var byKey: [TableKey: MetabaseTable] = [:]
            var byName: [String: MetabaseTable] = [:]
            for schema in grouped.keys.sorted() {
                for table in grouped[schema]! {
                    byKey[TableKey(schema: schema, name: table.name)] = table
                    if byName[table.name] == nil { byName[table.name] = table }
                }
            }
            tablesBySchema = grouped
            tableByKey = byKey
            tableByName = byName
        }
    }

    private let config: ResolvedConnectionConfig
    private let client: any MetabaseHTTPClient

    /// One Metabase database as the sidebar sees it. `engine` selects the SQL
    /// dialect for generated browse queries.
    struct DatabaseEntry {
        let displayName: String
        let id: Int
        let engine: String?
    }

    /// Databases sorted by display name. Names are usually unique; duplicates
    /// get an " (id)" suffix so every node stays addressable.
    private var databaseEntries: [DatabaseEntry] = []
    private var metadataByDatabaseID: [Int: CachedMetadata] = [:]
    /// Toolbar-selected target for native queries; driver-local, no SQL sent.
    private var activeDatabaseName: String?

    public init(config: ResolvedConnectionConfig) throws {
        self.config = config
        self.client = URLSessionMetabaseHTTPClient()
    }

    /// Test entry point with an injected transport.
    public init(config: ResolvedConnectionConfig, client: any MetabaseHTTPClient) {
        self.config = config
        self.client = client
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        activeDatabaseName = nil
        // `GET /api/database` doubles as the session check: a stale token
        // surfaces as 401 → .authenticationExpired through validate().
        try await loadDatabases()
    }

    public func disconnect() async {
        databaseEntries = []
        metadataByDatabaseID = [:]
        activeDatabaseName = nil
    }

    // MARK: - Namespaces

    public func listNamespaces(parent: Namespace?) async throws -> [Namespace] {
        guard let parent else {
            if databaseEntries.isEmpty { try await loadDatabases() }
            return databaseEntries.map {
                Namespace(path: [$0.displayName], kind: .database, isExpandable: true)
            }
        }

        switch parent.kind {
        case .database:
            let databaseName = parent.path[0]
            let metadata = try await metadata(forDatabaseNamed: databaseName)
            let schemas = metadata.tablesBySchema.keys.filter { !$0.isEmpty }.sorted()
            if schemas.count > 1 {
                // Schema nodes first, then any schema-less tables as direct
                // children so nothing becomes unreachable.
                let schemaNodes = schemas.map {
                    Namespace(path: [databaseName, $0], kind: .schema, isExpandable: true)
                }
                let looseTables = (metadata.tablesBySchema[""] ?? []).map {
                    Namespace(
                        path: [databaseName, $0.name],
                        kind: .table($0.tableKind),
                        isExpandable: false)
                }
                return schemaNodes + looseTables
            }
            return metadata.tablesBySchema.values
                .joined()
                .sorted { $0.name < $1.name }
                .map {
                    Namespace(
                        path: [databaseName, $0.name],
                        kind: .table($0.tableKind),
                        isExpandable: false)
                }
        case .schema:
            let databaseName = parent.path[0]
            let schema = parent.path[1]
            let metadata = try await metadata(forDatabaseNamed: databaseName)
            return (metadata.tablesBySchema[schema] ?? []).map {
                Namespace(
                    path: [databaseName, schema, $0.name],
                    kind: .table($0.tableKind),
                    isExpandable: false)
            }
        case .table:
            return []
        }
    }

    public func listColumns(of table: Namespace) async throws -> [ColumnMeta] {
        guard table.path.count >= 2 else { return [] }
        let databaseName = table.path[0]
        let schema = table.path.count >= 3 ? table.path[1] : nil
        let tableName = table.path.last ?? ""
        let metadata = try await metadata(forDatabaseNamed: databaseName)
        let match: MetabaseTable? = if let schema {
            metadata.tableByKey[TableKey(schema: schema, name: tableName)]
        } else {
            metadata.tableByKey[TableKey(schema: "", name: tableName)]
                ?? metadata.tableByName[tableName]
        }
        guard let match else {
            throw DBError(kind: .queryFailed, message: "Unknown table \"\(tableName)\"")
        }
        return (match.fields ?? []).map {
            ColumnMeta(name: $0.name, dbTypeName: $0.typeName)
        }
    }

    /// Stores the toolbar-selected database; nil restores auto-targeting.
    /// Overrides the SQL default — Metabase has no session to switch.
    public func setActiveNamespace(_ name: String?) async throws {
        activeDatabaseName = name
    }

    // MARK: - Query execution

    public func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        switch query {
        case .sql(let sql):
            // Editor queries run against the toolbar-selected database.
            return try await runNative(sql, databaseID: try targetDatabaseID(), pageSize: pageSize)
        case .tableBrowse(let request):
            // Browse routes to the table's own database and quotes for that
            // database's engine — a Metabase connection spans many dialects.
            let database = try database(named: request.path[0])
            let sql = Self.browseSQL(request, engine: database.engine)
            return try await runNative(sql, databaseID: database.id, pageSize: pageSize)
        case .mongo:
            throw DBError(kind: .unsupported, message: "Metabase driver only accepts SQL")
        }
    }

    /// Runs one native SQL statement against a specific Metabase database.
    private func runNative(
        _ sql: String, databaseID: Int, pageSize: Int
    ) async throws -> QueryExecution {
        var request = try makeRequest(path: "/api/dataset", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "database": databaseID,
            "type": "native",
            "native": ["query": sql],
        ])

        // URLSession honors cooperative cancellation, so cancelling the calling
        // task aborts the transfer; Metabase has no server-side cancel, the
        // 2000-row `/api/dataset` cap bounds the response instead.
        let data: Data
        do {
            let (body, response) = try await client.send(request)
            try validate(response, data: body, failureKind: .queryFailed)
            data = body
        } catch let error as DBError {
            throw error
        } catch is CancellationError {
            throw DBError(kind: .cancelled, message: "Query cancelled")
        } catch let error as URLError where error.code == .cancelled {
            throw DBError(kind: .cancelled, message: "Query cancelled")
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: "Could not reach Metabase",
                underlying: String(describing: error))
        }

        let (columns, rows) = try MetabaseResponseParser.datasetResult(from: data)
        return Self.execution(columns: columns, rows: rows, pageSize: pageSize)
    }

    /// Delivers already-materialized rows in `pageSize`-bounded chunks,
    /// yielded synchronously into the buffering stream.
    private static func execution(
        columns: [ColumnMeta], rows: [ResultRow], pageSize: Int
    ) -> QueryExecution {
        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>.makeStream()
        let size = max(1, pageSize)
        if rows.isEmpty {
            continuation.yield(QueryResultChunk(rows: [], isFinal: true))
        } else {
            var index = 0
            while index < rows.count {
                let end = min(index + size, rows.count)
                continuation.yield(QueryResultChunk(
                    rows: Array(rows[index..<end]),
                    isFinal: end == rows.count))
                index = end
            }
        }
        continuation.finish()
        return QueryExecution(columns: columns, chunks: stream, cancel: {})
    }

    private func targetDatabaseID() throws -> Int {
        if let activeDatabaseName { return try database(named: activeDatabaseName).id }
        if databaseEntries.count == 1 { return databaseEntries[0].id }
        throw DBError(kind: .queryFailed, message: "Select a database in the toolbar first.")
    }

    private func database(named name: String) throws -> DatabaseEntry {
        guard let entry = databaseEntries.first(where: { $0.displayName == name }) else {
            throw DBError(kind: .queryFailed, message: "Unknown database \"\(name)\"")
        }
        return entry
    }

    /// Builds a `SELECT` for browsing one table, quoted and paged for the
    /// target engine's dialect. Metabase runs native SQL verbatim against the
    /// backing engine, so MySQL needs backticks where Postgres needs quotes.
    static func browseSQL(_ request: TableBrowseRequest, engine: String?) -> String {
        let quote = identifierQuoting(for: engine)
        // Drop the leading database component — it is a Metabase routing label,
        // not a schema the engine resolves. What remains is [table] or
        // [schema, table].
        let tableRef = request.path.dropFirst().map(quote).joined(separator: ".")
        let projection = request.columns.isEmpty
            ? "*" : request.columns.map(quote).joined(separator: ", ")
        var sql = "SELECT \(projection) FROM \(tableRef)"
        if let filter = request.filter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filter.isEmpty {
            sql += " WHERE \(filter)"
        }
        sql += " LIMIT \(request.limit) OFFSET \(request.offset)"
        return sql
    }

    /// Returns an identifier-quoting function for a Metabase engine string.
    /// MySQL/MariaDB use backticks; SQL Server uses brackets; everything else
    /// falls back to standard double quotes.
    private static func identifierQuoting(for engine: String?) -> (String) -> String {
        switch engine {
        case "mysql", "mariadb":
            return { "`" + $0.replacingOccurrences(of: "`", with: "``") + "`" }
        case "sqlserver":
            return { "[" + $0.replacingOccurrences(of: "]", with: "]]") + "]" }
        default:
            return { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        }
    }

    // MARK: - Metadata fetching

    private func loadDatabases() async throws {
        let request = try makeRequest(path: "/api/database")
        let data = try await send(request, failureKind: .connectionFailed)
        let databases = try MetabaseResponseParser.databaseList(from: data)

        var counts: [String: Int] = [:]
        for database in databases { counts[database.name, default: 0] += 1 }
        databaseEntries = databases
            .map { database in
                let display = counts[database.name]! > 1
                    ? "\(database.name) (\(database.id))"
                    : database.name
                return DatabaseEntry(
                    displayName: display, id: database.id, engine: database.engine)
            }
            .sorted { $0.displayName < $1.displayName }
    }

    private func metadata(forDatabaseNamed name: String) async throws -> CachedMetadata {
        if databaseEntries.isEmpty { try await loadDatabases() }
        guard let entry = databaseEntries.first(where: { $0.displayName == name }) else {
            throw DBError(kind: .queryFailed, message: "Unknown database \"\(name)\"")
        }
        if let cached = metadataByDatabaseID[entry.id] { return cached }
        let request = try makeRequest(path: "/api/database/\(entry.id)/metadata")
        let data = try await send(request, failureKind: .connectionFailed)
        let metadata: MetabaseDatabaseMetadata
        do {
            metadata = try JSONDecoder().decode(MetabaseDatabaseMetadata.self, from: data)
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not parse metadata for \"\(name)\"",
                underlying: String(describing: error))
        }
        let cached = CachedMetadata(tables: metadata.tables ?? [])
        metadataByDatabaseID[entry.id] = cached
        return cached
    }

    // MARK: - HTTP plumbing

    private func makeRequest(path: String, method: String = "GET") throws -> URLRequest {
        guard let host = config.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            throw DBError(kind: .connectionFailed, message: "No Metabase URL configured")
        }
        var base = host.contains("://") ? host : "https://\(host)"
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw DBError(kind: .connectionFailed, message: "Invalid Metabase URL \"\(host)\"")
        }

        guard let token = config.password?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw DBError(
                kind: .authenticationExpired,
                message: "Not signed in to Metabase — sign in to create a session")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Metabase-Session")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest, failureKind: DBError.Kind) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.send(request)
        } catch let error as DBError {
            throw error
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not reach Metabase",
                underlying: String(describing: error))
        }
        try validate(response, data: data, failureKind: failureKind)
        return data
    }

    private func validate(
        _ response: HTTPURLResponse, data: Data, failureKind: DBError.Kind
    ) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw DBError(
                kind: .authenticationExpired,
                message: "Metabase session expired — disconnect and reconnect to sign in again.")
        default:
            let detail = MetabaseResponseParser.errorMessage(from: data)
            throw DBError(
                kind: failureKind,
                message: detail ?? "Metabase returned HTTP \(response.statusCode)",
                underlying: detail == nil ? nil : "HTTP \(response.statusCode)")
        }
    }
}
