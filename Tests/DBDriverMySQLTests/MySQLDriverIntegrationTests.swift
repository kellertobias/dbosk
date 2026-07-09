import DBCore
import Foundation
import Testing

@testable import DBDriverMySQL

/// Integration tests against the docker-compose MySQL (port 33069).
/// Enable with: DBOSK_MYSQL_TESTS=1 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBOSK_MYSQL_TESTS"] == "1"))
struct MySQLDriverIntegrationTests {
    private func makeDriver() throws -> MySQLDriver {
        try MySQLDriver(config: ResolvedConnectionConfig(
            host: "127.0.0.1",
            port: 33069,
            user: "root",
            password: "dbosk",
            database: "dbosk_test",
            tls: .preferred
        ))
    }

    private func collectAll(_ execution: QueryExecution) async throws -> [ResultRow] {
        var rows: [ResultRow] = []
        for try await chunk in execution.chunks {
            rows.append(contentsOf: chunk.rows)
        }
        return rows
    }

    @Test func connectAndSelectTypes() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        let execution = try await driver.execute(
            .sql("""
                SELECT CAST(42 AS SIGNED) AS answer, 'hi' AS greeting,
                       1.5E0 AS ratio, CAST(123.45 AS DECIMAL(10, 4)) AS exact,
                       CAST(NULL AS CHAR) AS nothing,
                       CAST('{"a": [1, 2], "b": {"c": true}}' AS JSON) AS doc
                """),
            pageSize: 100)

        #expect(execution.columns.map(\.name) == [
            "answer", "greeting", "ratio", "exact", "nothing", "doc",
        ])
        let rows = try await collectAll(execution)
        #expect(rows.count == 1)
        let values = rows[0].values
        #expect(values[0] == .int(42))
        #expect(values[1] == .string("hi"))
        #expect(values[2] == .double(1.5))
        #expect(values[3] == .decimal("123.4500"))
        #expect(values[4] == .null)
        guard case .document(let doc) = values[5] else {
            Issue.record("expected document, got \(values[5])")
            return
        }
        #expect(doc["a"] == .array([.int(1), .int(2)]))
        #expect(doc["b"] == .document(["c": .bool(true)]))
        await driver.disconnect()
    }

    @Test func streamsLargeResultInChunks() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        let setup = try await driver.execute(
            .sql("SET SESSION cte_max_recursion_depth = 20000"), pageSize: 10)
        _ = try? await collectAll(setup)

        // Recursive CTE to generate 10k rows.
        let execution = try await driver.execute(
            .sql("""
                WITH RECURSIVE seq(i) AS (
                    SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < 10000
                )
                SELECT i, MD5(i) FROM seq
                """),
            pageSize: 500)

        var chunkCount = 0
        var rowCount = 0
        for try await chunk in execution.chunks {
            chunkCount += 1
            rowCount += chunk.rows.count
            #expect(chunk.rows.count <= 500)
        }
        #expect(rowCount == 10000)
        #expect(chunkCount >= 20)
        await driver.disconnect()
    }

    @Test func cancelStopsARunningQuery() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        let setup = try await driver.execute(
            .sql("SET SESSION cte_max_recursion_depth = 100000000"), pageSize: 10)
        _ = try? await collectAll(setup)

        // Would produce 100M rows; must be stopped by KILL QUERY + producer cancel.
        let execution = try await driver.execute(
            .sql("""
                WITH RECURSIVE seq(i) AS (
                    SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < 100000000
                )
                SELECT i, MD5(i) FROM seq
                """),
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
            // Either our cancellation or the server's interrupt error is fine.
            #expect(error.kind == .cancelled || error.kind == .queryFailed)
        }
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(rowsSeen < 100_000_000)
        // Deterministic teardown: the killed connection is in a dirty state and
        // must be closed before the test process exits, or NIO crashes at exit.
        await driver.disconnect()
    }

    @Test func queryErrorSurfacesServerMessage() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        let execution = try? await driver.execute(
            .sql("SELECT * FROM does_not_exist"), pageSize: 10)
        var failed = false
        if let execution {
            do { _ = try await collectAll(execution) } catch let error as DBError {
                failed = error.kind == .queryFailed
                    && error.message.lowercased().contains("does_not_exist")
            }
        } else {
            failed = true
        }
        #expect(failed)
        await driver.disconnect()
    }

    @Test func listsDatabasesTablesAndColumns() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        let setup = try await driver.execute(
            .sql("CREATE TABLE IF NOT EXISTS dbosk_smoke (id INT PRIMARY KEY, note TEXT)"),
            pageSize: 10)
        _ = try? await collectAll(setup)

        let databases = try await driver.listNamespaces(parent: nil)
        let testDB = databases.first { $0.name == "dbosk_test" }
        #expect(testDB != nil)

        let tables = try await driver.listNamespaces(parent: testDB)
        let smoke = tables.first { $0.name == "dbosk_smoke" }
        #expect(smoke != nil)

        let columns = try await driver.listColumns(of: smoke!)
        #expect(columns.map(\.name) == ["id", "note"])
        #expect(columns[0].dbTypeName == "int")
        await driver.disconnect()
    }

    @Test func describesTableStructure() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        for sql in [
            "DROP TABLE IF EXISTS dbosk_structure",
            """
            CREATE TABLE dbosk_structure (
                id INT AUTO_INCREMENT PRIMARY KEY,
                email VARCHAR(190) NOT NULL,
                status VARCHAR(20) DEFAULT 'open',
                score DOUBLE,
                UNIQUE KEY idx_structure_email (email),
                KEY idx_structure_status (status, email)
            )
            """,
        ] {
            let setup = try await driver.execute(.sql(sql), pageSize: 10)
            _ = try await collectAll(setup)
        }

        let structure = try await driver.describeTable(Namespace(
            path: ["dbosk_test", "dbosk_structure"],
            kind: .table(.table),
            isExpandable: false))

        #expect(structure.columns.map(\.name) == ["id", "email", "status", "score"])
        let id = structure.columns[0]
        #expect(id.isPrimaryKey)
        #expect(!id.isNullable)
        #expect(!structure.columns[1].isNullable)
        #expect(structure.columns[2].defaultValue == "open")
        #expect(structure.columns[3].isNullable)

        #expect(structure.indexes.first?.name == "PRIMARY")
        #expect(structure.indexes.first?.isPrimary == true)
        #expect(structure.indexes.first?.isUnique == true)
        #expect(structure.indexes.first?.columns == ["id"])
        let email = structure.indexes.first { $0.name == "idx_structure_email" }
        #expect(email?.isUnique == true)
        let status = structure.indexes.first { $0.name == "idx_structure_status" }
        #expect(status?.isUnique == false)
        #expect(status?.columns == ["status", "email"])
        await driver.disconnect()
    }
}
