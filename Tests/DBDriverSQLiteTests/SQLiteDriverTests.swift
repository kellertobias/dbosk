import DBCore
import Foundation
import GRDB
import Testing

@testable import DBDriverSQLite

/// SQLite tests need no server, so they always run.
@Suite struct SQLiteDriverTests {
    private func makeDatabase() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE people (
                    id INTEGER PRIMARY KEY, name TEXT, score REAL, avatar BLOB
                );
                CREATE VIEW active_people AS SELECT * FROM people;
                """)
            for index in 0..<1000 {
                try db.execute(
                    sql: "INSERT INTO people (name, score) VALUES (?, ?)",
                    arguments: ["person\(index)", Double(index) / 2])
            }
        }
        return path
    }

    private func makeDriver(_ path: String) throws -> SQLiteDriver {
        try SQLiteDriver(config: ResolvedConnectionConfig(filePath: path))
    }

    private func collectAll(_ execution: QueryExecution) async throws -> [ResultRow] {
        var rows: [ResultRow] = []
        for try await chunk in execution.chunks {
            rows.append(contentsOf: chunk.rows)
        }
        return rows
    }

    @Test func selectTypesAndNull() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        let execution = try await driver.execute(
            .sql("SELECT 42 AS answer, 'hi' AS greeting, 1.5 AS ratio, NULL AS missing, x'0102' AS blob"),
            pageSize: 10)
        #expect(execution.columns.map(\.name) == [
            "answer", "greeting", "ratio", "missing", "blob",
        ])
        let rows = try await collectAll(execution)
        let values = rows[0].values
        #expect(values[0] == .int(42))
        #expect(values[1] == .string("hi"))
        #expect(values[2] == .double(1.5))
        #expect(values[3] == .null)
        #expect(values[4] == .bytes(Data([1, 2])))
        await driver.disconnect()
    }

    @Test func streamsInChunks() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        let execution = try await driver.execute(
            .sql("SELECT * FROM people"), pageSize: 100)
        var chunks = 0
        var rows = 0
        for try await chunk in execution.chunks {
            chunks += 1
            rows += chunk.rows.count
            #expect(chunk.rows.count <= 100)
        }
        #expect(rows == 1000)
        #expect(chunks >= 10)
        await driver.disconnect()
    }

    @Test func cancelInterruptsLongQuery() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        // Cartesian self-joins: billions of rows, must be interrupted.
        let execution = try await driver.execute(
            .sql("SELECT a.id FROM people a, people b, people c"),
            pageSize: 100)
        let started = Date()
        var rowsSeen = 0
        do {
            for try await chunk in execution.chunks {
                rowsSeen += chunk.rows.count
                if rowsSeen >= 200 {
                    await execution.cancel()
                }
            }
        } catch let error as DBError {
            #expect(error.kind == .cancelled)
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(rowsSeen < 1_000_000_000)
        await driver.disconnect()
    }

    @Test func listsTablesViewsAndColumns() async throws {
        let path = try makeDatabase()
        let driver = try makeDriver(path)
        try await driver.connect()

        let roots = try await driver.listNamespaces(parent: nil)
        #expect(roots.count == 1)
        #expect(roots[0].name == "test.sqlite")

        let tables = try await driver.listNamespaces(parent: roots[0])
        #expect(tables.contains { $0.name == "people" && $0.kind == .table(.table) })
        #expect(tables.contains { $0.name == "active_people" && $0.kind == .table(.view) })

        let people = tables.first { $0.name == "people" }!
        let columns = try await driver.listColumns(of: people)
        #expect(columns.map(\.name) == ["id", "name", "score", "avatar"])
        #expect(columns[0].dbTypeName == "INTEGER")
        await driver.disconnect()
    }

    @Test func describesTableStructure() async throws {
        let path = try makeDatabase()
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE orders (
                    id INTEGER PRIMARY KEY,
                    customer TEXT NOT NULL,
                    status TEXT DEFAULT 'open',
                    total REAL
                );
                CREATE INDEX idx_orders_status ON orders(status, customer);
                CREATE UNIQUE INDEX idx_orders_customer ON orders(customer);
                """)
        }
        let driver = try makeDriver(path)
        try await driver.connect()

        let structure = try await driver.describeTable(
            Namespace(path: ["orders"], kind: .table(.table), isExpandable: false))

        #expect(structure.columns.map(\.name) == ["id", "customer", "status", "total"])
        let id = structure.columns[0]
        #expect(id.isPrimaryKey)
        #expect(id.dbTypeName == "INTEGER")
        let customer = structure.columns[1]
        #expect(!customer.isNullable)
        #expect(!customer.isPrimaryKey)
        let status = structure.columns[2]
        #expect(status.isNullable)
        #expect(status.defaultValue == "'open'")

        // Synthetic PRIMARY KEY entry first (rowid alias has no real index),
        // then the named indexes.
        #expect(structure.indexes.first?.isPrimary == true)
        #expect(structure.indexes.first?.columns == ["id"])
        let statusIndex = structure.indexes.first { $0.name == "idx_orders_status" }
        #expect(statusIndex?.columns == ["status", "customer"])
        #expect(statusIndex?.isUnique == false)
        let customerIndex = structure.indexes.first { $0.name == "idx_orders_customer" }
        #expect(customerIndex?.isUnique == true)
        await driver.disconnect()
    }

    @Test func describesViewWithoutIndexes() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()
        let structure = try await driver.describeTable(
            Namespace(path: ["active_people"], kind: .table(.view), isExpandable: false))
        // Views have columns but no indexes in SQLite.
        #expect(structure.columns.map(\.name) == ["id", "name", "score", "avatar"])
        #expect(structure.indexes.isEmpty)
        await driver.disconnect()
    }

    @Test func errorSurfacesMessage() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        var sawError = false
        do {
            let execution = try await driver.execute(
                .sql("SELECT * FROM does_not_exist"), pageSize: 10)
            _ = try await collectAll(execution)
        } catch let error as DBError {
            sawError = error.kind == .queryFailed
                && error.message.contains("does_not_exist")
        }
        #expect(sawError)
        await driver.disconnect()
    }

    @Test func missingFileFailsToConnect() async throws {
        let driver = try makeDriver("/nonexistent/nope.sqlite")
        await #expect(throws: DBError.self) {
            try await driver.connect()
        }
    }

    @Test func dmlReportsAffectedCount() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        let execution = try await driver.execute(
            .sql("UPDATE people SET score = 0 WHERE id <= 10"), pageSize: 10)
        var affected: Int?
        for try await chunk in execution.chunks where chunk.isFinal {
            affected = chunk.affectedCount
        }
        #expect(affected == 10)
        await driver.disconnect()
    }
}
