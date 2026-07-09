import DBCore
import Foundation
import Testing

@testable import DBDriverMongo

@Suite struct MongoQueryParserTests {
    @Test func parsesFind() throws {
        let query = try MongoQueryParser.parse(
            #"db.users.find({"status": "active"})"#)
        #expect(query.collection == "users")
        #expect(query.operation == .find)
        #expect(query.body == #"{"status": "active"}"#)
        #expect(query.skip == nil)
        #expect(query.limit == nil)
    }

    @Test func parsesSkipLimitAndSemicolon() throws {
        let query = try MongoQueryParser.parse(
            "db.orders.find({}).skip(20).limit(10);")
        #expect(query.collection == "orders")
        #expect(query.skip == 20)
        #expect(query.limit == 10)
    }

    @Test func parsesEmptyFind() throws {
        let query = try MongoQueryParser.parse("db.users.find()")
        #expect(query.body == "{}")
    }

    @Test func parsesAggregate() throws {
        let query = try MongoQueryParser.parse(
            #"db.sales.aggregate([{"$match": {"x": 1}}, {"$group": {"_id": "$y"}}])"#)
        #expect(query.operation == .aggregate)
        #expect(query.body.hasPrefix("[") && query.body.hasSuffix("]"))
    }

    @Test func parsesParensInsideStrings() throws {
        let query = try MongoQueryParser.parse(
            #"db.logs.find({"msg": "hello (world)"})"#)
        #expect(query.body == #"{"msg": "hello (world)"}"#)
    }

    @Test func rejectsGarbage() {
        #expect(throws: DBError.self) {
            _ = try MongoQueryParser.parse("SELECT * FROM users")
        }
    }
}

/// Integration tests against the docker-compose Mongo (port 27019).
/// Enable with: DBOSK_MONGO_TESTS=1 swift test
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["DBOSK_MONGO_TESTS"] == "1"),
    .serialized)  // tests share the seeded "people" collection
struct MongoDriverIntegrationTests {
    private func makeDriver() throws -> MongoDriver {
        try MongoDriver(config: ResolvedConnectionConfig(
            host: "localhost",
            port: 27019,
            database: "dbosk_test",
            tls: .disabled
        ))
    }

    private func collectAll(_ execution: QueryExecution) async throws -> [ResultRow] {
        var rows: [ResultRow] = []
        for try await chunk in execution.chunks {
            rows.append(contentsOf: chunk.rows)
        }
        return rows
    }

    private func seed(_ driver: MongoDriver) async throws {
        // Idempotent seed via the app's own query path is not possible
        // (no inserts in v1), so use MongoKitten directly.
        let db = try await MongoKitten.MongoDatabase.connect(
            to: "mongodb://localhost:27019/dbosk_test")
        try await db["people"].drop()
        var documents: [BSON.Document] = []
        for index in 0..<250 {
            documents.append([
                "n": index,
                "name": "person\(index)",
                "active": index % 2 == 0,
                "meta": ["tags": ["a", "b"], "score": 1.5] as BSON.Document,
            ])
        }
        _ = try await db["people"].insertMany(documents)
    }

    @Test func findStreamsAndMapsDocuments() async throws {
        let driver = try makeDriver()
        try await driver.connect()
        try await seed(driver)

        let execution = try await driver.execute(
            .sql(#"db.people.find({"active": true})"#), pageSize: 50)
        #expect(execution.columns.map(\.name) == ["document"])

        var chunks = 0
        var rows: [ResultRow] = []
        for try await chunk in execution.chunks {
            chunks += 1
            rows.append(contentsOf: chunk.rows)
        }
        #expect(rows.count == 125)
        #expect(chunks >= 3)

        guard case .document(let doc) = rows[0].values[0] else {
            Issue.record("expected document")
            return
        }
        #expect(doc["active"] == .bool(true))
        #expect(doc["name"] == .string("person0"))
        guard case .document(let meta)? = doc["meta"] else {
            Issue.record("expected nested document")
            return
        }
        #expect(meta["tags"] == .array([.string("a"), .string("b")]))
        #expect(meta["score"] == .double(1.5))
    }

    @Test func skipAndLimitPaginate() async throws {
        let driver = try makeDriver()
        try await driver.connect()
        try await seed(driver)

        let execution = try await driver.execute(
            .sql("db.people.find({}).skip(100).limit(20)"), pageSize: 50)
        let rows = try await collectAll(execution)
        #expect(rows.count == 20)
        guard case .document(let doc) = rows[0].values[0] else {
            Issue.record("expected document")
            return
        }
        #expect(doc["n"] == .int(100))
    }

    @Test func aggregateAndCount() async throws {
        let driver = try makeDriver()
        try await driver.connect()
        try await seed(driver)

        let aggregate = try await driver.execute(
            .sql(#"db.people.aggregate([{"$match": {"active": true}}, {"$count": "total"}])"#),
            pageSize: 10)
        let aggregateRows = try await collectAll(aggregate)
        #expect(aggregateRows.count == 1)
        if case .document(let doc) = aggregateRows[0].values[0] {
            #expect(doc["total"] == .int(125))
        }

        let count = try await driver.execute(
            .sql("db.people.count({})"), pageSize: 10)
        let countRows = try await collectAll(count)
        #expect(countRows[0].values[0] == .int(250))
    }

    @Test func cancelStopsCursorIteration() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        // Seed a larger collection so cancellation lands mid-cursor.
        let db = try await MongoKitten.MongoDatabase.connect(
            to: "mongodb://localhost:27019/dbosk_test")
        try await db["bulk"].drop()
        for batch in 0..<10 {
            var documents: [BSON.Document] = []
            for index in 0..<2000 {
                documents.append(["n": batch * 2000 + index, "payload": String(repeating: "x", count: 200)])
            }
            _ = try await db["bulk"].insertMany(documents)
        }

        let execution = try await driver.execute(
            .sql("db.bulk.find({})"), pageSize: 100)
        var rowsSeen = 0
        do {
            for try await chunk in execution.chunks {
                rowsSeen += chunk.rows.count
                if rowsSeen >= 300 {
                    await execution.cancel()
                }
            }
        } catch let error as DBError {
            #expect(error.kind == .cancelled)
        }
        #expect(rowsSeen < 20000)
        await driver.disconnect()
    }

    @Test func listsDatabasesCollectionsAndFields() async throws {
        let driver = try makeDriver()
        try await driver.connect()
        try await seed(driver)

        let databases = try await driver.listNamespaces(parent: nil)
        let testDB = databases.first { $0.name == "dbosk_test" }
        #expect(testDB != nil)

        let collections = try await driver.listNamespaces(parent: testDB)
        let people = collections.first { $0.name == "people" }
        #expect(people != nil)
        #expect(people?.kind == .table(.collection))

        let fields = try await driver.listColumns(of: people!)
        #expect(fields.contains { $0.name == "name" && $0.dbTypeName == "string" })
        #expect(fields.contains { $0.name == "_id" && $0.dbTypeName == "objectId" })
    }

    @Test func describesCollectionStructure() async throws {
        let driver = try makeDriver()
        try await driver.connect()
        try await seed(driver)

        let structure = try await driver.describeTable(Namespace(
            path: ["dbosk_test", "people"],
            kind: .table(.collection),
            isExpandable: false))

        #expect(structure.columns.contains { $0.name == "_id" })
        // Every collection carries the default _id_ index.
        let idIndex = structure.indexes.first { $0.name == "_id_" }
        #expect(idIndex != nil)
        #expect(idIndex?.columns == ["_id"])
        #expect(idIndex?.isPrimary == true)
    }
}

import BSON
import MongoKitten
