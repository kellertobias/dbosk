import Foundation
import Testing

@testable import DBCore

@Suite struct ActiveNamespaceStatementBuilderTests {
    @Test func postgresSetsSearchPath() {
        #expect(
            ActiveNamespaceStatementBuilder.statement(
                activating: "analytics", dialect: .postgres)
            == #"SET search_path TO "analytics""#)
        #expect(
            ActiveNamespaceStatementBuilder.statement(
                activating: nil, dialect: .postgres)
            == "SET search_path TO DEFAULT")
    }

    @Test func mysqlUsesDatabase() {
        #expect(
            ActiveNamespaceStatementBuilder.statement(
                activating: "shop", dialect: .mysql)
            == "USE `shop`")
        // No reset statement exists; callers switch to a concrete database.
        #expect(
            ActiveNamespaceStatementBuilder.statement(
                activating: nil, dialect: .mysql)
            == nil)
    }

    @Test func identifiersAreQuoteEscaped() {
        #expect(
            ActiveNamespaceStatementBuilder.statement(
                activating: #"we"ird"#, dialect: .postgres)
            == #"SET search_path TO "we""ird""#)
        #expect(
            ActiveNamespaceStatementBuilder.statement(
                activating: "we`ird", dialect: .mysql)
            == "USE `we``ird`")
    }

    @Test func sqliteHasNoActiveNamespace() {
        #expect(
            ActiveNamespaceStatementBuilder.statement(
                activating: "main", dialect: .sqlite)
            == nil)
    }
}
