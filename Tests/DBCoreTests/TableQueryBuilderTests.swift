import Foundation
import Testing

@testable import DBCore

@Suite struct TableQueryBuilderTests {
    private let postgres = DriverDescriptor(
        id: "postgres", displayName: "PostgreSQL", queryLanguage: .sql,
        defaultPort: 5432, supportsStreaming: true, supportsServerSideCancel: true)
    private let mysql = DriverDescriptor(
        id: "mysql", displayName: "MySQL", queryLanguage: .sql,
        defaultPort: 3306, supportsStreaming: true, supportsServerSideCancel: true,
        identifierQuote: "`")
    private let mongo = DriverDescriptor(
        id: "mongodb", displayName: "MongoDB", queryLanguage: .mongo,
        defaultPort: 27017, supportsStreaming: true, supportsServerSideCancel: false,
        identifierQuote: "")

    private var table: Namespace {
        Namespace(path: ["public", "users"], kind: .table(.table), isExpandable: false)
    }

    @Test func postgresDefaults() {
        let sql = TableQueryBuilder.build(.init(table: table), for: postgres)
        #expect(sql == #"SELECT * FROM "public"."users" LIMIT 100 OFFSET 0"#)
    }

    @Test func postgresColumnsFilterAndPaging() {
        let sql = TableQueryBuilder.build(
            .init(
                table: table, columns: ["id", "name"],
                filter: "status = 'active'", offset: 200, limit: 50),
            for: postgres)
        #expect(sql == #"SELECT "id", "name" FROM "public"."users" WHERE status = 'active' LIMIT 50 OFFSET 200"#)
    }

    @Test func mysqlUsesBackticks() {
        let sql = TableQueryBuilder.build(
            .init(table: Namespace(
                path: ["shop", "order"], kind: .table(.table), isExpandable: false)),
            for: mysql)
        #expect(sql == "SELECT * FROM `shop`.`order` LIMIT 100 OFFSET 0")
    }

    @Test func quoteEscaping() {
        let sql = TableQueryBuilder.build(
            .init(table: Namespace(
                path: ["public", #"we"ird"#], kind: .table(.table), isExpandable: false)),
            for: postgres)
        #expect(sql.contains(#""we""ird""#))
    }

    @Test func mongoFilterAndPaging() {
        let query = TableQueryBuilder.build(
            .init(
                table: Namespace(
                    path: ["dbosk_test", "people"], kind: .table(.collection),
                    isExpandable: false),
                filter: #"{"active": true}"#, offset: 20, limit: 10),
            for: mongo)
        #expect(query == #"db.dbosk_test.people.find({"active": true}).skip(20).limit(10)"#)
    }

    @Test func mongoEmptyFilterNoSkip() {
        let query = TableQueryBuilder.build(
            .init(
                table: Namespace(
                    path: ["dbosk_test", "people"], kind: .table(.collection),
                    isExpandable: false)),
            for: mongo)
        #expect(query == "db.dbosk_test.people.find({}).limit(100)")
    }

    @Test func redisBuildsScan() {
        let redis = DriverDescriptor(
            id: "redis", displayName: "Redis", queryLanguage: .redis,
            defaultPort: 6379, supportsStreaming: true,
            supportsServerSideCancel: false, identifierQuote: "")
        let keyspace = Namespace(path: ["db0"], kind: .table(.table), isExpandable: false)
        #expect(TableQueryBuilder.build(.init(table: keyspace), for: redis)
            == "SCAN 0 MATCH * COUNT 100")
        #expect(TableQueryBuilder.build(
            .init(table: keyspace, filter: "user:*", limit: 50), for: redis)
            == "SCAN 0 MATCH user:* COUNT 50")
    }

    @Test func partiqlOmitsLimitOffset() {
        let dynamo = DriverDescriptor(
            id: "dynamodb", displayName: "DynamoDB", queryLanguage: .partiql,
            defaultPort: nil, supportsStreaming: true,
            supportsServerSideCancel: false)
        let table = Namespace(path: ["people"], kind: .table(.table), isExpandable: false)
        #expect(TableQueryBuilder.build(
            .init(table: table, filter: "active = true", offset: 10, limit: 5),
            for: dynamo)
            == #"SELECT * FROM "people" WHERE active = true"#)
    }

    @Test func clampsInvalidPaging() {
        let sql = TableQueryBuilder.build(
            .init(table: table, offset: -5, limit: 0), for: postgres)
        #expect(sql.hasSuffix("LIMIT 1 OFFSET 0"))
    }
}
