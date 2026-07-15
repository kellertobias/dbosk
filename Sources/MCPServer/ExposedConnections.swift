import Connections
import DBCore

/// One active dbOSK connection as seen by the MCP server. The `driver`
/// closure hands out the session's *dedicated read-only* driver — never the
/// UI session's primary connection.
public struct ExposedConnection: Sendable {
    /// Connection-profile UUID string; the `connection_id` in tool calls.
    public let id: String
    public let name: String
    /// Engine display name (PostgreSQL, MySQL, …).
    public let engine: String
    public let queryLanguage: DriverDescriptor.QueryLanguage
    public let sqlDialect: SQLDialect?
    public let explainSupport: DriverDescriptor.ExplainSupport
    /// The user's MCP opt-in and namespace allowlist for this profile.
    public let access: MCPAccessConfig
    public let driver: @Sendable () async throws -> any DatabaseDriver

    public init(
        id: String,
        name: String,
        engine: String,
        queryLanguage: DriverDescriptor.QueryLanguage,
        sqlDialect: SQLDialect?,
        explainSupport: DriverDescriptor.ExplainSupport,
        access: MCPAccessConfig,
        driver: @escaping @Sendable () async throws -> any DatabaseDriver
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.queryLanguage = queryLanguage
        self.sqlDialect = sqlDialect
        self.explainSupport = explainSupport
        self.access = access
        self.driver = driver
    }
}

/// Feeds the MCP server the current set of active connections. Includes
/// sessions that are *not* opted in — tools filter on `access.enabled` so a
/// call addressing a non-enabled connection gets an actionable "enable it in
/// dbOSK settings" error rather than a bare not-found.
public protocol MCPConnectionProvider: Sendable {
    func connections() async -> [ExposedConnection]
}
