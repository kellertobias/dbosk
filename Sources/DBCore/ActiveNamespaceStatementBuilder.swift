import Foundation

/// Builds the dialect statement that redirects unqualified SQL names to a
/// schema/database for the rest of the session. Pure string building,
/// unit-testable in DBCore (mirrors `ExplainStatementBuilder`).
public enum ActiveNamespaceStatementBuilder {
    /// Nil when the dialect has no session-switchable namespace (SQLite) or
    /// when asked to reset on a dialect without a reset statement (MySQL has
    /// no "un-USE"; callers switch back to a concrete database instead).
    public static func statement(
        activating name: String?, dialect: SQLDialect
    ) -> String? {
        switch dialect {
        case .postgres:
            guard let name else { return "SET search_path TO DEFAULT" }
            return "SET search_path TO \(quoted(name, with: "\""))"
        case .mysql:
            guard let name else { return nil }
            return "USE \(quoted(name, with: "`"))"
        case .sqlite:
            return nil
        }
    }

    private static func quoted(_ identifier: String, with quote: String) -> String {
        quote + identifier.replacingOccurrences(of: quote, with: quote + quote) + quote
    }
}

extension DatabaseDriver {
    public func setActiveNamespace(_ name: String?) async throws {
        let descriptor = Self.descriptor
        guard descriptor.activeNamespaceKind != nil,
              let dialect = descriptor.sqlDialect,
              let statement = ActiveNamespaceStatementBuilder.statement(
                activating: name, dialect: dialect)
        else {
            throw DBError(
                kind: .unsupported,
                message: "\(descriptor.displayName) cannot switch the active "
                    + (descriptor.activeNamespaceKind?.displayName.lowercased()
                        ?? "namespace"))
        }
        let execution = try await execute(.sql(statement), pageSize: 1)
        for try await _ in execution.chunks {}
    }
}
