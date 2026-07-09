import DBCore
import Foundation
import SotoDynamoDB
import Testing

@testable import DBDriverDynamoDB

/// Integration tests against docker dynamodb-local (port 8009).
/// Enable with: DBOSK_DDB_TESTS=1 swift test
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["DBOSK_DDB_TESTS"] == "1"),
    .serialized)
struct DynamoDBDriverIntegrationTests {
    private static let endpoint = "http://localhost:8009"

    private func makeDriver() throws -> DynamoDBDriver {
        try DynamoDBDriver(config: ResolvedConnectionConfig(
            host: "us-east-1",
            user: "dummy",
            password: "dummy",
            uri: Self.endpoint
        ))
    }

    private func collectAll(_ execution: QueryExecution) async throws -> [ResultRow] {
        var rows: [ResultRow] = []
        for try await chunk in execution.chunks {
            rows.append(contentsOf: chunk.rows)
        }
        return rows
    }

    private func seed() async throws {
        let client = AWSClient(
            credentialProvider: .static(accessKeyId: "dummy", secretAccessKey: "dummy"))
        let dynamo = DynamoDB(client: client, region: .useast1, endpoint: Self.endpoint)
        let existing = try await dynamo.listTables(DynamoDB.ListTablesInput())
        if existing.tableNames?.contains("dbosk_people") != true {
            _ = try await dynamo.createTable(DynamoDB.CreateTableInput(
                attributeDefinitions: [
                    .init(attributeName: "pk", attributeType: .s)
                ],
                billingMode: .payPerRequest,
                keySchema: [.init(attributeName: "pk", keyType: .hash)],
                tableName: "dbosk_people"))
        }
        for index in 0..<25 {
            _ = try await dynamo.putItem(DynamoDB.PutItemInput(
                item: [
                    "pk": .s("person\(index)"),
                    "age": .n("\(20 + index)"),
                    "active": .bool(index % 2 == 0),
                    "tags": .l([.s("a"), .s("b")]),
                    "meta": .m(["score": .n("1.5")]),
                ],
                tableName: "dbosk_people"))
        }
        try await client.shutdown()
    }

    @Test func listsTablesAndKeyColumns() async throws {
        try await seed()
        let driver = try makeDriver()
        try await driver.connect()

        let tables = try await driver.listNamespaces(parent: nil)
        let people = tables.first { $0.name == "dbosk_people" }
        #expect(people != nil)

        let columns = try await driver.listColumns(of: people!)
        #expect(columns.contains { $0.name == "pk" && $0.dbTypeName.contains("HASH") })

        await driver.disconnect()
    }

    @Test func partiqlSelectMapsDocuments() async throws {
        try await seed()
        let driver = try makeDriver()
        try await driver.connect()

        let execution = try await driver.execute(
            .sql(#"SELECT * FROM "dbosk_people" WHERE active = true"#), pageSize: 10)
        #expect(execution.columns.map(\.name) == ["document"])
        let rows = try await collectAll(execution)
        #expect(rows.count == 13)

        guard case .document(let doc) = rows[0].values[0] else {
            Issue.record("expected document")
            return
        }
        #expect(doc["active"] == .bool(true))
        if case .decimal(let age)? = doc["age"] {
            #expect(Int(age) != nil)
        } else {
            Issue.record("expected decimal age")
        }
        #expect(doc["tags"] == .array([.string("a"), .string("b")]))
        #expect(doc["meta"] == .document(["score": .decimal("1.5")]))

        await driver.disconnect()
    }

    @Test func describesTableStructure() async throws {
        try await seed()
        let driver = try makeDriver()
        try await driver.connect()

        let structure = try await driver.describeTable(
            Namespace(path: ["dbosk_people"], kind: .table(.table), isExpandable: false))
        #expect(structure.columns.map(\.name) == ["pk"])
        #expect(structure.columns[0].isPrimaryKey)
        #expect(structure.indexes.first?.isPrimary == true)
        #expect(structure.indexes.first?.columns == ["pk (HASH)"])

        await driver.disconnect()
    }

    @Test func queryErrorSurfaces() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        var failed = false
        do {
            let execution = try await driver.execute(
                .sql(#"SELECT * FROM "no_such_table""#), pageSize: 10)
            _ = try await collectAll(execution)
        } catch let error as DBError {
            failed = error.kind == .queryFailed
        }
        #expect(failed)
        await driver.disconnect()
    }
}
