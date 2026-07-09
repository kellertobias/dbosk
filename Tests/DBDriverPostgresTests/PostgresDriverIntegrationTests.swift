import DBCore
import Foundation
import Testing

@testable import DBDriverPostgres

/// Integration tests against the docker-compose Postgres (port 54329).
/// Enable with: DBOSK_PG_TESTS=1 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBOSK_PG_TESTS"] == "1"))
struct PostgresDriverIntegrationTests {
    private func makeDriver() throws -> PostgresDriver {
        try PostgresDriver(config: ResolvedConnectionConfig(
            host: "localhost",
            port: 54329,
            user: "dbosk",
            password: "dbosk",
            database: "dbosk_test",
            tls: .disabled
        ))
    }

    private func collectAll(
        _ execution: QueryExecution
    ) async throws -> [ResultRow] {
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
                SELECT 42::int4 AS answer, 'hi'::text AS greeting, true AS flag,
                       1.5::float8 AS ratio, 123.4500::numeric AS exact,
                       NULL::text AS nothing,
                       '{"a": [1, 2], "b": {"c": true}}'::jsonb AS doc
                """),
            pageSize: 100)

        #expect(execution.columns.map(\.name) == [
            "answer", "greeting", "flag", "ratio", "exact", "nothing", "doc",
        ])
        let rows = try await collectAll(execution)
        #expect(rows.count == 1)
        let values = rows[0].values
        #expect(values[0] == .int(42))
        #expect(values[1] == .string("hi"))
        #expect(values[2] == .bool(true))
        #expect(values[3] == .double(1.5))
        #expect(values[4] == .decimal("123.45"))
        #expect(values[5] == .null)
        guard case .document(let doc) = values[6] else {
            Issue.record("expected document, got \(values[6])")
            return
        }
        #expect(doc["a"] == .array([.int(1), .int(2)]))
        #expect(doc["b"] == .document(["c": .bool(true)]))
        await driver.disconnect()
    }

    @Test func streamsLargeResultInChunks() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        let execution = try await driver.execute(
            .sql("SELECT i, md5(i::text) FROM generate_series(1, 10000) AS s(i)"),
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

        // A query that would take far longer than the test timeout.
        let execution = try await driver.execute(
            .sql("SELECT i, md5(i::text) FROM generate_series(1, 100000000) AS s(i)"),
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
        #expect(rowsSeen < 100_000_000)
        await driver.disconnect()
    }

    @Test func queryErrorSurfacesServerMessage() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        await #expect {
            _ = try await driver.execute(.sql("SELECT * FROM does_not_exist"), pageSize: 10)
        } throws: { error in
            guard let dbError = error as? DBError else { return false }
            return dbError.kind == .queryFailed
                && dbError.message.contains("does_not_exist")
        }
        await driver.disconnect()
    }

    @Test func listsSchemasAndTables() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        // Ensure at least one table exists.
        let setup = try await driver.execute(
            .sql("CREATE TABLE IF NOT EXISTS dbosk_smoke (id int primary key, note text)"),
            pageSize: 10)
        _ = try? await collectAll(setup)

        let schemas = try await driver.listNamespaces(parent: nil)
        let publicSchema = schemas.first { $0.name == "public" }
        #expect(publicSchema != nil)

        let tables = try await driver.listNamespaces(parent: publicSchema)
        let smoke = tables.first { $0.name == "dbosk_smoke" }
        #expect(smoke != nil)

        let columns = try await driver.listColumns(of: smoke!)
        #expect(columns.map(\.name) == ["id", "note"])
        #expect(columns[0].dbTypeName == "integer")
        await driver.disconnect()
    }

    @Test func describesTableStructure() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        for sql in [
            "DROP TABLE IF EXISTS dbosk_structure",
            """
            CREATE TABLE dbosk_structure (
                id serial PRIMARY KEY,
                email text NOT NULL,
                status text DEFAULT 'open',
                score float8
            )
            """,
            "CREATE UNIQUE INDEX idx_structure_email ON dbosk_structure(email)",
            "CREATE INDEX idx_structure_status ON dbosk_structure(status, email)",
        ] {
            let setup = try await driver.execute(.sql(sql), pageSize: 10)
            _ = try await collectAll(setup)
        }

        let structure = try await driver.describeTable(Namespace(
            path: ["public", "dbosk_structure"],
            kind: .table(.table),
            isExpandable: false))

        #expect(structure.columns.map(\.name) == ["id", "email", "status", "score"])
        let id = structure.columns[0]
        #expect(id.isPrimaryKey)
        #expect(!id.isNullable)
        #expect(id.defaultValue?.contains("nextval") == true)
        #expect(!structure.columns[1].isNullable)
        #expect(structure.columns[2].defaultValue?.contains("open") == true)
        #expect(structure.columns[3].isNullable)

        #expect(structure.indexes.first?.isPrimary == true)
        #expect(structure.indexes.first?.columns == ["id"])
        let email = structure.indexes.first { $0.name == "idx_structure_email" }
        #expect(email?.isUnique == true)
        #expect(email?.method == "btree")
        let status = structure.indexes.first { $0.name == "idx_structure_status" }
        #expect(status?.isUnique == false)
        #expect(status?.columns == ["status", "email"])
        await driver.disconnect()
    }
}
