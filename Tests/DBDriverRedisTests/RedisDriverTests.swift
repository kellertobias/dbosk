import DBCore
import Foundation
import Testing

@testable import DBDriverRedis

@Suite struct RedisCommandParserTests {
    @Test func tokenizesQuotedStrings() {
        #expect(RedisCommandParser.tokenize(#"SET greeting "hello world""#)
            == ["SET", "greeting", "hello world"])
        #expect(RedisCommandParser.tokenize("GET   key1") == ["GET", "key1"])
        #expect(RedisCommandParser.tokenize(#"SET empty """#) == ["SET", "empty", ""])
    }

    @Test func parsesScanOptions() throws {
        let options = try RedisCommandParser.scanOptions(
            RedisCommandParser.tokenize("SCAN 0 MATCH user:* COUNT 50"))
        #expect(options.match == "user:*")
        #expect(options.count == 50)

        let defaults = try RedisCommandParser.scanOptions(
            RedisCommandParser.tokenize("SCAN 0"))
        #expect(defaults.match == "*")
        #expect(defaults.count == 100)
    }

    @Test func rejectsBadScanOptions() {
        #expect(throws: DBError.self) {
            _ = try RedisCommandParser.scanOptions(
                RedisCommandParser.tokenize("SCAN 0 BOGUS 1"))
        }
    }
}

/// Integration tests against the docker-compose Redis (port 63799).
/// Enable with: DBOSK_REDIS_TESTS=1 swift test
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["DBOSK_REDIS_TESTS"] == "1"),
    .serialized)
struct RedisDriverIntegrationTests {
    private func makeDriver() throws -> RedisDriver {
        try RedisDriver(config: ResolvedConnectionConfig(
            host: "localhost", port: 63799, tls: .disabled))
    }

    private func collectAll(_ execution: QueryExecution) async throws -> [ResultRow] {
        var rows: [ResultRow] = []
        for try await chunk in execution.chunks {
            rows.append(contentsOf: chunk.rows)
        }
        return rows
    }

    private func run(_ driver: RedisDriver, _ command: String) async throws -> [ResultRow] {
        try await collectAll(try await driver.execute(.sql(command), pageSize: 100))
    }

    @Test func setGetAndTypes() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        let ok = try await run(driver, #"SET dbosk:test "hello world""#)
        #expect(ok[0].values[0] == .string("OK"))

        let value = try await run(driver, "GET dbosk:test")
        #expect(value[0].values[0] == .string("hello world"))

        _ = try await run(driver, "DEL dbosk:counter")
        let counter = try await run(driver, "INCR dbosk:counter")
        #expect(counter[0].values[0] == .int(1))

        let missing = try await run(driver, "GET dbosk:does-not-exist")
        #expect(missing[0].values[0] == .null)

        _ = try await run(driver, "DEL dbosk:list")
        _ = try await run(driver, "RPUSH dbosk:list a b c")
        let list = try await run(driver, "LRANGE dbosk:list 0 -1")
        #expect(list.map { $0.values[0] } == [.string("a"), .string("b"), .string("c")])

        await driver.disconnect()
    }

    @Test func scanStreamsMatchingKeys() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        for index in 0..<500 {
            _ = try await run(driver, "SET dbosk:scan:\(index) x")
        }
        let rows = try await collectAll(try await driver.execute(
            .sql("SCAN 0 MATCH dbosk:scan:* COUNT 200"), pageSize: 50))
        #expect(rows.count == 200)  // capped at COUNT
        #expect(rows.allSatisfy {
            $0.values[0].displayString.hasPrefix("dbosk:scan:")
        })

        let all = try await collectAll(try await driver.execute(
            .sql("SCAN 0 MATCH dbosk:scan:* COUNT 10000"), pageSize: 100))
        #expect(all.count == 500)

        await driver.disconnect()
    }

    @Test func errorReplySurfaces() async throws {
        let driver = try makeDriver()
        try await driver.connect()

        var failed = false
        do {
            _ = try await run(driver, "NOTACOMMAND foo")
        } catch let error as DBError {
            failed = error.kind == .queryFailed
        }
        #expect(failed)
        await driver.disconnect()
    }

    @Test func listsKeyspaceNamespace() async throws {
        let driver = try makeDriver()
        try await driver.connect()
        let roots = try await driver.listNamespaces(parent: nil)
        #expect(roots.count == 1)
        #expect(roots[0].name == "db0")
        #expect(roots[0].kind == .table(.table))
        await driver.disconnect()
    }
}
