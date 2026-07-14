import DBCore
import Foundation
import Testing

@testable import DBDriverMetabase

// MARK: - Browse SQL (per-engine quoting)

@Suite struct MetabaseBrowseSQLTests {
    private func req(_ path: [String], columns: [String] = [], filter: String? = nil)
        -> TableBrowseRequest
    {
        TableBrowseRequest(path: path, columns: columns, filter: filter, limit: 100, offset: 0)
    }

    @Test func mysqlUsesBackticks() {
        let sql = MetabaseDriver.browseSQL(req(["db", "course_v2"]), engine: "mysql")
        #expect(sql == "SELECT * FROM `course_v2` LIMIT 100 OFFSET 0")
    }

    @Test func postgresUsesDoubleQuotesAndSchema() {
        let sql = MetabaseDriver.browseSQL(req(["db", "public", "users"]), engine: "postgres")
        #expect(sql == "SELECT * FROM \"public\".\"users\" LIMIT 100 OFFSET 0")
    }

    @Test func unknownEngineFallsBackToDoubleQuotes() {
        let sql = MetabaseDriver.browseSQL(req(["db", "t"]), engine: nil)
        #expect(sql == "SELECT * FROM \"t\" LIMIT 100 OFFSET 0")
    }

    @Test func projectsAndFiltersSelectedColumns() {
        let sql = MetabaseDriver.browseSQL(
            req(["db", "t"], columns: ["a", "b"], filter: "a > 1"), engine: "mysql")
        #expect(sql == "SELECT `a`, `b` FROM `t` WHERE a > 1 LIMIT 100 OFFSET 0")
    }

    @Test func escapesIdentifierQuotes() {
        let sql = MetabaseDriver.browseSQL(req(["db", "we`ird"]), engine: "mysql")
        #expect(sql == "SELECT * FROM `we``ird` LIMIT 100 OFFSET 0")
    }
}

// MARK: - Mock transport

/// Canned-response transport keyed by "METHOD /path"; records every request
/// so tests can assert on bodies and headers.
private actor MockHTTPClient: MetabaseHTTPClient {
    struct Route: Sendable {
        let status: Int
        let body: String

        init(_ status: Int, _ body: String) {
            self.status = status
            self.body = body
        }
    }

    private let routes: [String: Route]
    private(set) var requests: [URLRequest] = []

    init(routes: [String: Route]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        guard let route = routes[key] else {
            throw DBError(kind: .connectionFailed, message: "No mock route for \(key)")
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: route.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(route.body.utf8), response)
    }

    /// Decoded JSON body of the most recent request to `path`, as `DBValue`
    /// so the result crosses the actor boundary as a Sendable value.
    func lastBody(forPath path: String) -> [String: DBValue]? {
        guard let data = requests.last(where: { $0.url?.path == path })?.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data),
              case .document(let dict) = DBValue.fromJSONObject(object)
        else { return nil }
        return dict
    }
}

// MARK: - Fixtures

private let twoDatabasesEnvelopeJSON = """
    {"data": [
        {"id": 3, "name": "Analytics", "engine": "postgres"},
        {"id": 7, "name": "Warehouse", "engine": "mysql"}
    ]}
    """

private let singleDatabaseBareArrayJSON = """
    [{"id": 3, "name": "Analytics", "engine": "postgres"}]
    """

private let singleSchemaMetadataJSON = """
    {"tables": [
        {"id": 10, "name": "users", "schema": "public", "fields": [
            {"id": 100, "name": "id", "database_type": "int8", "base_type": "type/BigInteger"},
            {"id": 101, "name": "email", "database_type": "varchar", "base_type": "type/Text"},
            {"id": 102, "name": "score", "base_type": "type/Float"}
        ]},
        {"id": 11, "name": "active_users", "schema": "public", "is_view": true, "fields": []}
    ]}
    """

private let multiSchemaMetadataJSON = """
    {"tables": [
        {"id": 20, "name": "orders", "schema": "sales", "fields": []},
        {"id": 21, "name": "refunds", "schema": "sales", "fields": []},
        {"id": 22, "name": "events", "schema": "tracking", "fields": []}
    ]}
    """

private let mixedSchemaMetadataJSON = """
    {"tables": [
        {"id": 20, "name": "orders", "schema": "sales", "fields": []},
        {"id": 22, "name": "events", "schema": "tracking", "fields": []},
        {"id": 23, "name": "loose", "schema": null, "fields": []},
        {"id": 24, "name": "blank", "schema": "", "is_view": true, "fields": []}
    ]}
    """

private let datasetSuccessJSON = """
    {"status": "completed", "data": {
        "cols": [
            {"name": "id", "database_type": "int8", "base_type": "type/BigInteger"},
            {"name": "name", "base_type": "type/Text"},
            {"name": "ratio", "database_type": "float8"},
            {"name": "active", "database_type": "bool"},
            {"name": "payload", "database_type": "jsonb"}
        ],
        "rows": [
            [1, "alice", 0.5, true, {"a": [1, 2]}],
            [2, "bob", 1.25, false, null],
            [3, null, null, null, null],
            [4, "dora", 2.0, true, null],
            [5, "eve", 3.5, false, null]
        ]
    }}
    """

private func driver(
    routes: [String: MockHTTPClient.Route],
    token: String? = "session-token"
) -> (MetabaseDriver, MockHTTPClient) {
    let client = MockHTTPClient(routes: routes)
    let config = ResolvedConnectionConfig(host: "metabase.example.com", password: token)
    return (MetabaseDriver(config: config, client: client), client)
}

private func standardRoutes(
    databases: String = twoDatabasesEnvelopeJSON
) -> [String: MockHTTPClient.Route] {
    [
        "GET /api/database": .init(200, databases),
        "GET /api/database/3/metadata": .init(200, singleSchemaMetadataJSON),
        "GET /api/database/7/metadata": .init(200, multiSchemaMetadataJSON),
    ]
}

private func collectChunks(_ execution: QueryExecution) async throws -> [QueryResultChunk] {
    var chunks: [QueryResultChunk] = []
    for try await chunk in execution.chunks { chunks.append(chunk) }
    return chunks
}

// MARK: - Tests

@Suite struct MetabaseDriverTests {
    @Test func descriptorID() {
        #expect(MetabaseDriver.descriptor.id == "metabase")
        #expect(!MetabaseDriver.descriptor.supportsSSHTunnel)
        #expect(!MetabaseDriver.descriptor.supportsDatabaseQualifiedSQL)
        #expect(MetabaseDriver.descriptor.rootNamespacesDefaultHidden)
    }

    @Test func databaseListEnvelopeShape() async throws {
        let (driver, _) = driver(routes: standardRoutes())
        try await driver.connect()
        let roots = try await driver.listNamespaces(parent: nil)
        #expect(roots.map(\.name) == ["Analytics", "Warehouse"])
        #expect(roots.allSatisfy { $0.kind == .database && $0.isExpandable })
    }

    @Test func databaseListBareArrayShape() async throws {
        let (driver, _) = driver(routes: standardRoutes(databases: singleDatabaseBareArrayJSON))
        try await driver.connect()
        let roots = try await driver.listNamespaces(parent: nil)
        #expect(roots.map(\.name) == ["Analytics"])
    }

    @Test func duplicateDatabaseNamesAreDisambiguated() async throws {
        let routes = standardRoutes(databases: """
            {"data": [
                {"id": 3, "name": "Analytics", "engine": "postgres"},
                {"id": 7, "name": "Analytics", "engine": "mysql"}
            ]}
            """)
        let (driver, _) = driver(routes: routes)
        try await driver.connect()
        let roots = try await driver.listNamespaces(parent: nil)
        #expect(roots.map(\.name) == ["Analytics (3)", "Analytics (7)"])
    }

    @Test func singleSchemaDatabaseListsTablesDirectly() async throws {
        let (driver, _) = driver(routes: standardRoutes())
        try await driver.connect()
        let parent = Namespace(path: ["Analytics"], kind: .database, isExpandable: true)
        let children = try await driver.listNamespaces(parent: parent)
        #expect(children.map(\.name) == ["active_users", "users"])
        #expect(children.map(\.path) == [["Analytics", "active_users"], ["Analytics", "users"]])
        #expect(children[0].kind == .table(.view))
        #expect(children[1].kind == .table(.table))
    }

    @Test func multiSchemaDatabaseListsSchemaNodes() async throws {
        let (driver, _) = driver(routes: standardRoutes())
        try await driver.connect()
        let parent = Namespace(path: ["Warehouse"], kind: .database, isExpandable: true)
        let schemas = try await driver.listNamespaces(parent: parent)
        #expect(schemas.map(\.name) == ["sales", "tracking"])
        #expect(schemas.allSatisfy { $0.kind == .schema && $0.isExpandable })

        let sales = try await driver.listNamespaces(parent: schemas[0])
        #expect(sales.map(\.path) == [
            ["Warehouse", "sales", "orders"],
            ["Warehouse", "sales", "refunds"],
        ])
    }

    @Test func listColumnsMapsTypes() async throws {
        let (driver, _) = driver(routes: standardRoutes())
        try await driver.connect()
        let table = Namespace(
            path: ["Analytics", "users"], kind: .table(.table), isExpandable: false)
        let columns = try await driver.listColumns(of: table)
        #expect(columns == [
            ColumnMeta(name: "id", dbTypeName: "int8"),
            ColumnMeta(name: "email", dbTypeName: "varchar"),
            // No database_type: falls back to base_type with "type/" stripped.
            ColumnMeta(name: "score", dbTypeName: "Float"),
        ])
    }

    @Test func executeMapsValuesAndChunks() async throws {
        var routes = standardRoutes()
        routes["POST /api/dataset"] = .init(200, datasetSuccessJSON)
        let (driver, _) = driver(routes: routes)
        try await driver.connect()
        try await driver.setActiveNamespace("Analytics")

        let execution = try await driver.execute(.sql("SELECT * FROM users"), pageSize: 2)
        #expect(execution.columns == [
            ColumnMeta(name: "id", dbTypeName: "int8"),
            ColumnMeta(name: "name", dbTypeName: "Text"),
            ColumnMeta(name: "ratio", dbTypeName: "float8"),
            ColumnMeta(name: "active", dbTypeName: "bool"),
            ColumnMeta(name: "payload", dbTypeName: "jsonb"),
        ])

        let chunks = try await collectChunks(execution)
        #expect(chunks.map(\.rows.count) == [2, 2, 1])
        #expect(chunks.map(\.isFinal) == [false, false, true])

        let first = chunks[0].rows[0].values
        #expect(first[0] == .int(1))
        #expect(first[1] == .string("alice"))
        #expect(first[2] == .double(0.5))
        #expect(first[3] == .bool(true))
        #expect(first[4] == .document(["a": .array([.int(1), .int(2)])]))
        #expect(chunks[1].rows[0].values == [.int(3), .null, .null, .null, .null])
    }

    @Test func multiSchemaDatabaseKeepsSchemalessTablesReachable() async throws {
        var routes = standardRoutes()
        routes["GET /api/database/7/metadata"] = .init(200, mixedSchemaMetadataJSON)
        let (driver, _) = driver(routes: routes)
        try await driver.connect()
        let parent = Namespace(path: ["Warehouse"], kind: .database, isExpandable: true)
        let children = try await driver.listNamespaces(parent: parent)

        // Sorted schema nodes first, then nil/empty-schema tables directly.
        #expect(children.map(\.name) == ["sales", "tracking", "blank", "loose"])
        #expect(children[0].kind == .schema)
        #expect(children[1].kind == .schema)
        #expect(children[2].kind == .table(.view))
        #expect(children[3].kind == .table(.table))
        #expect(children[2].path == ["Warehouse", "blank"])
        #expect(children[3].path == ["Warehouse", "loose"])
    }

    @Test func datasetNullErrorParsesAsSuccess() async throws {
        var routes = standardRoutes()
        routes["POST /api/dataset"] = .init(200, """
            {"status": "completed", "error": null, "data": {
                "cols": [{"name": "id", "base_type": "type/Integer"}],
                "rows": [[1]]
            }}
            """)
        let (driver, _) = driver(routes: routes)
        try await driver.connect()
        try await driver.setActiveNamespace("Analytics")

        let execution = try await driver.execute(.sql("SELECT 1"), pageSize: 100)
        let chunks = try await collectChunks(execution)
        #expect(chunks.map(\.isFinal) == [true])
        #expect(chunks[0].rows.map(\.values) == [[.int(1)]])
    }

    @Test func executeRejectsNonSQL() async throws {
        let (driver, _) = driver(routes: standardRoutes())
        try await driver.connect()
        await #expect(throws: DBError.self) {
            _ = try await driver.execute(
                .mongo(collection: "c", operation: .find, body: "{}"), pageSize: 100)
        }
    }

    @Test func executeSurfacesFailedStatus() async throws {
        var routes = standardRoutes()
        routes["POST /api/dataset"] = .init(
            200, #"{"status": "failed", "error": "Table \"nope\" not found"}"#)
        let (driver, _) = driver(routes: routes)
        try await driver.connect()
        try await driver.setActiveNamespace("Analytics")

        do {
            _ = try await driver.execute(.sql("SELECT 1"), pageSize: 100)
            Issue.record("expected queryFailed")
        } catch let error as DBError {
            #expect(error.kind == .queryFailed)
            #expect(error.message == "Table \"nope\" not found")
        }
    }

    @Test func rejectedSessionBecomesAuthenticationExpired() async throws {
        let routes: [String: MockHTTPClient.Route] = [
            "GET /api/database": .init(401, #"{"message": "Unauthenticated"}"#)
        ]
        let (driver, _) = driver(routes: routes)
        do {
            try await driver.connect()
            Issue.record("expected authenticationExpired")
        } catch let error as DBError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains("disconnect and reconnect"))
        }
    }

    @Test func missingTokenBecomesAuthenticationExpired() async throws {
        let (driver, _) = driver(routes: standardRoutes(), token: nil)
        do {
            try await driver.connect()
            Issue.record("expected authenticationExpired")
        } catch let error as DBError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains("Not signed in"))
        }
    }

    @Test func executeWithoutActiveDatabaseRequiresSelection() async throws {
        let (driver, _) = driver(routes: standardRoutes())
        try await driver.connect()
        do {
            _ = try await driver.execute(.sql("SELECT 1"), pageSize: 100)
            Issue.record("expected queryFailed")
        } catch let error as DBError {
            #expect(error.kind == .queryFailed)
            #expect(error.message == "Select a database in the toolbar first.")
        }
    }

    @Test func singleDatabaseIsAutoTargeted() async throws {
        var routes = standardRoutes(databases: singleDatabaseBareArrayJSON)
        routes["POST /api/dataset"] = .init(200, datasetSuccessJSON)
        let (driver, client) = driver(routes: routes)
        try await driver.connect()

        let execution = try await driver.execute(.sql("SELECT 1"), pageSize: 100)
        _ = try await collectChunks(execution)

        let body = await client.lastBody(forPath: "/api/dataset")
        #expect(body?["database"] == .int(3))
        #expect(body?["type"] == .string("native"))
        #expect(body?["native"] == .document(["query": .string("SELECT 1")]))
    }

    @Test func activeNamespaceSelectsQueryTarget() async throws {
        var routes = standardRoutes()
        routes["POST /api/dataset"] = .init(200, datasetSuccessJSON)
        let (driver, client) = driver(routes: routes)
        try await driver.connect()
        try await driver.setActiveNamespace("Warehouse")

        _ = try await driver.execute(.sql("SELECT 1"), pageSize: 100)
        let body = await client.lastBody(forPath: "/api/dataset")
        #expect(body?["database"] == .int(7))

        // Clearing restores the multi-database "pick one" requirement.
        try await driver.setActiveNamespace(nil)
        await #expect(throws: DBError.self) {
            _ = try await driver.execute(.sql("SELECT 1"), pageSize: 100)
        }
    }

    @Test func sessionTokenIsSentAsHeader() async throws {
        let (driver, client) = driver(routes: standardRoutes())
        try await driver.connect()
        let requests = await client.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Metabase-Session") == "session-token"
        })
    }
}
