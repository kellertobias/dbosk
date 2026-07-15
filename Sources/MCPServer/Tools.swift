import Connections
import DBCore
import Foundation
import Logging
import MCP

/// A tool-level failure: reported to the client as a tool error (so LLM
/// clients can read the reason and self-correct), never as a protocol error.
struct ToolError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

/// The MCP tool surface. Read-only by construction: no tool maps to
/// `executeBatch` or any other write path, all SQL passes `ReadOnlySQLGate`,
/// Mongo bodies pass `MongoReadOnlyGate`, and every relation is checked
/// against the profile's allowlist.
struct MCPToolbox: Sendable {
    let provider: any MCPConnectionProvider
    let logger: Logger

    /// Truncation bound for a single oversized cell in the JSON payload.
    static let maxCellCharacters = 10_000

    func register(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.toolDefinitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await handle(params)
        }
    }

    private func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text: String
            switch params.name {
            case "list_connections":
                text = try await listConnections()
            case "list_namespaces":
                text = try await listNamespaces(params.arguments)
            case "describe_table":
                text = try await describeTable(params.arguments)
            case "query":
                text = try await query(params.arguments)
            case "mongo_query":
                text = try await mongoQuery(params.arguments)
            case "explain_query":
                text = try await explainQuery(params.arguments)
            default:
                throw ToolError("Unknown tool '\(params.name)'")
            }
            return .init(content: [.text(text)], isError: false)
        } catch {
            let message = (error as? CustomStringConvertible)?.description
                ?? String(describing: error)
            logger.info("Tool call failed", metadata: [
                "tool": "\(params.name)", "error": "\(message)",
            ])
            return .init(content: [.text(message)], isError: true)
        }
    }

    // MARK: - Argument helpers

    private func string(_ args: [String: Value]?, _ key: String) -> String? {
        args?[key]?.stringValue
    }

    private func stringArray(_ args: [String: Value]?, _ key: String) -> [String]? {
        guard let values = args?[key]?.arrayValue else { return nil }
        return values.compactMap(\.stringValue)
    }

    private func limits(_ args: [String: Value]?) -> MCPQueryLimits {
        var limits = MCPQueryLimits()
        if let rows = args?["max_rows"]?.intValue { limits.maxRows = rows }
        if let bytes = args?["max_bytes"]?.intValue { limits.maxBytes = bytes }
        if let timeout = args?["timeout_seconds"]?.doubleValue {
            limits.timeoutSeconds = timeout
        } else if let timeout = args?["timeout_seconds"]?.intValue {
            limits.timeoutSeconds = Double(timeout)
        }
        return limits.clamped()
    }

    /// Resolves and authorizes the addressed connection.
    private func connection(_ args: [String: Value]?) async throws -> ExposedConnection {
        guard let id = string(args, "connection_id") else {
            throw ToolError("Missing required argument 'connection_id'. Call list_connections first.")
        }
        let all = await provider.connections()
        guard let match = all.first(where: { $0.id == id }) else {
            throw ToolError(
                "Unknown connection_id '\(id)'. Call list_connections for the "
                + "connections currently available over MCP.")
        }
        guard match.access.enabled else {
            throw ToolError(
                "Connection '\(match.name)' is not enabled for MCP. Enable it in "
                + "dbOSK → Settings → MCP → Connections, then retry.")
        }
        return match
    }

    // MARK: - Allowlist checks

    /// Whether a relation reference is inside the allowlist. References may
    /// be unqualified (`users` for an allowlisted `public.users`), so a
    /// reference also passes when it matches the tail of an entry.
    private func relationAllowed(_ path: [String], access: MCPAccessConfig) -> Bool {
        if access.allowsReading(path: path) { return true }
        guard case .allowlist(let entries) = access.scope else { return access.enabled }
        let lowered = path.map { $0.lowercased() }
        return entries.contains { entry in
            let entryLowered = entry.map { $0.lowercased() }
            return entryLowered.count >= lowered.count
                && Array(entryLowered.suffix(lowered.count)) == lowered
        }
    }

    private func requireRelationsAllowed(
        _ relations: [[String]], connection: ExposedConnection
    ) throws {
        for path in relations where !relationAllowed(path, access: connection.access) {
            throw ToolError(
                "Table '\(path.joined(separator: "."))' is not in the MCP allowlist "
                + "for connection '\(connection.name)'. Adjust the allowlist in "
                + "dbOSK → Settings → MCP → Connections.")
        }
    }

    /// Layer 3b: independently verify the tables a SELECT-like statement
    /// touches via the engine's own plan, catching anything the tokenizer
    /// extraction missed. Fails closed when the plan cannot be produced.
    private func verifyPlanRelations(
        sql: String, connection: ExposedConnection, driver: any DatabaseDriver
    ) async throws {
        guard case .allowlist = connection.access.scope else { return }
        guard connection.explainSupport != .none, let dialect = connection.sqlDialect else { return }
        let leading = try ReadOnlySQLGate.leadingKeyword(sql, dialect: dialect)
        guard ["SELECT", "WITH", "VALUES", "TABLE"].contains(leading) else { return }

        let plan: ExplainPlan
        do {
            plan = try await driver.explain(.sql(sql), analyze: false)
        } catch {
            throw ToolError(
                "Could not verify the tables this query reads (EXPLAIN failed: "
                + "\(error)). Queries on allowlist-restricted connections must be "
                + "verifiable.")
        }
        var names: [String] = []
        collectRelations(plan.root, into: &names)
        for name in names where !relationAllowed([name], access: connection.access) {
            throw ToolError(
                "Query plan touches table '\(name)', which is not in the MCP "
                + "allowlist for connection '\(connection.name)'.")
        }
    }

    private func collectRelations(_ node: PlanNode, into names: inout [String]) {
        if let relation = node.relation { names.append(relation) }
        for child in node.children { collectRelations(child, into: &names) }
    }

    // MARK: - Tools

    private func listConnections() async throws -> String {
        let connections = await provider.connections().filter(\.access.enabled)
        let payload = connections.map { connection -> [String: Any] in
            [
                "connection_id": connection.id,
                "name": connection.name,
                "engine": connection.engine,
                "query_language": connection.queryLanguage == .mongo ? "mongo" : "sql",
            ]
        }
        if payload.isEmpty {
            return jsonText([
                "connections": [] as [Any],
                "hint": "No connections are enabled for MCP. In dbOSK, connect to a "
                    + "database and enable it under Settings → MCP → Connections.",
            ])
        }
        return jsonText(["connections": payload])
    }

    private func listNamespaces(_ args: [String: Value]?) async throws -> String {
        let connection = try await connection(args)
        let parentPath = stringArray(args, "parent_path") ?? []
        let driver = try await connection.driver()

        var parent: Namespace?
        for (index, name) in parentPath.enumerated() {
            let children = try await driver.listNamespaces(parent: parent)
            guard let match = children.first(where: {
                $0.name.lowercased() == name.lowercased()
            }) else {
                let path = parentPath.prefix(index + 1).joined(separator: ".")
                throw ToolError("Namespace '\(path)' not found on '\(connection.name)'.")
            }
            parent = match
        }
        let children = try await driver.listNamespaces(parent: parent)
            .filter { connection.access.allows(path: $0.path) }
        return jsonText([
            "namespaces": children.map { namespace -> [String: Any] in
                [
                    "name": namespace.name,
                    "path": namespace.path,
                    "kind": namespace.kind.description,
                    "expandable": namespace.isExpandable,
                ]
            }
        ])
    }

    private func describeTable(_ args: [String: Value]?) async throws -> String {
        let connection = try await connection(args)
        guard let path = stringArray(args, "path"), !path.isEmpty else {
            throw ToolError("Missing required argument 'path' (array of namespace "
                + "components, e.g. [\"public\", \"users\"]).")
        }
        try requireRelationsAllowed([path], connection: connection)
        let driver = try await connection.driver()
        let table = Namespace(path: path, kind: .table(.table), isExpandable: false)
        let structure = try await driver.describeTable(table)
        return jsonText([
            "columns": structure.columns.map { column -> [String: Any] in
                [
                    "name": column.name,
                    "type": column.dbTypeName,
                    "nullable": column.isNullable,
                    "default": column.defaultValue as Any? ?? NSNull(),
                    "primary_key": column.isPrimaryKey,
                ]
            },
            "indexes": structure.indexes.map { index -> [String: Any] in
                [
                    "name": index.name,
                    "columns": index.columns,
                    "unique": index.isUnique,
                    "primary": index.isPrimary,
                    "method": index.method as Any? ?? NSNull(),
                ]
            },
        ])
    }

    private func query(_ args: [String: Value]?) async throws -> String {
        let connection = try await connection(args)
        guard connection.queryLanguage == .sql, let dialect = connection.sqlDialect else {
            throw ToolError(
                "Connection '\(connection.name)' does not speak SQL. "
                + (connection.queryLanguage == .mongo
                    ? "Use the mongo_query tool instead." : ""))
        }
        guard let sql = string(args, "sql"), !sql.isEmpty else {
            throw ToolError("Missing required argument 'sql'.")
        }

        // Layer 1: SQL gate. Layer 3a: tokenizer-extracted relations.
        try ReadOnlySQLGate.validate(sql, dialect: dialect)
        let relations = try ReadOnlySQLGate.referencedRelations(sql, dialect: dialect)
        try requireRelationsAllowed(relations.map(\.path), connection: connection)

        // Layer 2 lives in the driver (read-only session). Layer 3b:
        let driver = try await connection.driver()
        try await verifyPlanRelations(sql: sql, connection: connection, driver: driver)

        let limits = limits(args)
        let result = try await ReadOnlyQueryRunner.run(
            driver: driver, query: .sql(sql), limits: limits)
        return resultText(result, limits: limits)
    }

    private func mongoQuery(_ args: [String: Value]?) async throws -> String {
        let connection = try await connection(args)
        guard connection.queryLanguage == .mongo else {
            throw ToolError(
                "Connection '\(connection.name)' is not a MongoDB connection. "
                + "Use the query tool for SQL engines.")
        }
        guard let collection = string(args, "collection"), !collection.isEmpty else {
            throw ToolError("Missing required argument 'collection'.")
        }
        guard let operationName = string(args, "operation"),
            let operation = MongoOperation(rawValue: operationName)
        else {
            throw ToolError("Argument 'operation' must be one of: find, aggregate, count.")
        }
        let body = string(args, "body") ?? ""

        try MongoReadOnlyGate.validate(operation: operation, body: body)
        try requireRelationsAllowed([[collection]], connection: connection)

        let driver = try await connection.driver()
        let limits = limits(args)
        let result = try await ReadOnlyQueryRunner.run(
            driver: driver,
            query: .mongo(collection: collection, operation: operation, body: body),
            limits: limits)
        return resultText(result, limits: limits)
    }

    private func explainQuery(_ args: [String: Value]?) async throws -> String {
        let connection = try await connection(args)
        guard connection.queryLanguage == .sql, let dialect = connection.sqlDialect else {
            throw ToolError("explain_query is only available for SQL connections.")
        }
        guard connection.explainSupport != .none else {
            throw ToolError("'\(connection.engine)' does not support query plans.")
        }
        guard let sql = string(args, "sql"), !sql.isEmpty else {
            throw ToolError("Missing required argument 'sql'.")
        }
        try ReadOnlySQLGate.validate(sql, dialect: dialect)
        let relations = try ReadOnlySQLGate.referencedRelations(sql, dialect: dialect)
        try requireRelationsAllowed(relations.map(\.path), connection: connection)

        let driver = try await connection.driver()
        // Never analyze: EXPLAIN ANALYZE executes the query.
        let plan = try await driver.explain(.sql(sql), analyze: false)
        return jsonText(["plan": planJSON(plan.root)])
    }

    private func planJSON(_ node: PlanNode) -> [String: Any] {
        var json: [String: Any] = ["operation": node.operation]
        if let detail = node.detail { json["detail"] = detail }
        if let relation = node.relation { json["relation"] = relation }
        if let index = node.indexName { json["index"] = index }
        if let cost = node.estimatedCost { json["estimated_cost"] = cost }
        if let rows = node.estimatedRows { json["estimated_rows"] = rows }
        if !node.children.isEmpty { json["children"] = node.children.map(planJSON) }
        return json
    }

    // MARK: - Result serialization

    private func resultText(_ result: ReadOnlyQueryResult, limits: MCPQueryLimits) -> String {
        let rows = result.rows.map { row in
            row.map { truncatedCell($0.jsonObject) }
        }
        return jsonText([
            "columns": result.columns.map { ["name": $0.name, "type": $0.dbTypeName] },
            "rows": rows,
            "row_count": result.rows.count,
            "truncated": result.truncated,
            "limits_applied": [
                "max_rows": limits.maxRows,
                "max_bytes": limits.maxBytes,
                "timeout_seconds": limits.timeoutSeconds,
            ],
        ])
    }

    /// Bounds one cell in the payload; huge blobs/documents get cut with a
    /// marker rather than flooding the client's context window.
    private func truncatedCell(_ value: Any) -> Any {
        guard let text = value as? String, text.count > Self.maxCellCharacters else {
            return value
        }
        return text.prefix(Self.maxCellCharacters)
            + "… [truncated, \(text.count) characters total]"
    }

    private func jsonText(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    // MARK: - Tool definitions

    static let toolDefinitions: [Tool] = [
        Tool(
            name: "list_connections",
            description: """
                Lists the database connections currently available over MCP \
                (active dbOSK connections the user has enabled for MCP). \
                Returns connection_id values used by every other tool.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
            ]),
            annotations: .init(title: "List connections", readOnlyHint: true)
        ),
        Tool(
            name: "list_namespaces",
            description: """
                Lists databases/schemas/tables under a parent path (omit \
                parent_path for the root). Only namespaces the user allowed \
                for MCP are returned.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "connection_id": .object([
                        "type": "string",
                        "description": "Connection id from list_connections",
                    ]),
                    "parent_path": .object([
                        "type": "array",
                        "items": .object(["type": "string"]),
                        "description":
                            "Path components of the parent namespace, e.g. [\"public\"]",
                    ]),
                ]),
                "required": .array(["connection_id"]),
            ]),
            annotations: .init(title: "List namespaces", readOnlyHint: true)
        ),
        Tool(
            name: "describe_table",
            description: "Describes a table: columns (name, type, nullability, "
                + "default, primary key) and indexes.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "connection_id": .object(["type": "string"]),
                    "path": .object([
                        "type": "array",
                        "items": .object(["type": "string"]),
                        "description":
                            "Full namespace path of the table, e.g. [\"public\", \"users\"]",
                    ]),
                ]),
                "required": .array(["connection_id", "path"]),
            ]),
            annotations: .init(title: "Describe table", readOnlyHint: true)
        ),
        Tool(
            name: "query",
            description: """
                Runs a single read-only SQL statement (SELECT/WITH/VALUES/\
                SHOW/EXPLAIN). Writes, DDL, multiple statements, and \
                session-altering commands are rejected. Results are capped: \
                max_rows (default \(MCPQueryLimits.defaultMaxRows), max \
                \(MCPQueryLimits.hardMaxRows)), max_bytes (default \
                \(MCPQueryLimits.defaultMaxBytes)), timeout_seconds (default \
                \(Int(MCPQueryLimits.defaultTimeoutSeconds)), max \
                \(Int(MCPQueryLimits.hardTimeoutSeconds))).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "connection_id": .object(["type": "string"]),
                    "sql": .object([
                        "type": "string",
                        "description": "One read-only SQL statement",
                    ]),
                    "max_rows": .object(["type": "integer"]),
                    "max_bytes": .object(["type": "integer"]),
                    "timeout_seconds": .object(["type": "number"]),
                ]),
                "required": .array(["connection_id", "sql"]),
            ]),
            annotations: .init(title: "Run read-only SQL", readOnlyHint: true)
        ),
        Tool(
            name: "mongo_query",
            description: """
                Runs a read-only MongoDB operation (find, aggregate, count) \
                against one collection. Aggregation pipelines containing \
                $out or $merge are rejected. body is a JSON filter (find/\
                count) or pipeline array (aggregate). Same caps as query.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "connection_id": .object(["type": "string"]),
                    "collection": .object(["type": "string"]),
                    "operation": .object([
                        "type": "string",
                        "enum": .array(["find", "aggregate", "count"]),
                    ]),
                    "body": .object([
                        "type": "string",
                        "description":
                            "JSON filter document or aggregation pipeline array",
                    ]),
                    "max_rows": .object(["type": "integer"]),
                    "timeout_seconds": .object(["type": "number"]),
                ]),
                "required": .array(["connection_id", "collection", "operation"]),
            ]),
            annotations: .init(title: "Run read-only Mongo query", readOnlyHint: true)
        ),
        Tool(
            name: "explain_query",
            description: "Reports the engine's execution plan for a read-only "
                + "SQL statement without running it (never ANALYZE).",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "connection_id": .object(["type": "string"]),
                    "sql": .object(["type": "string"]),
                ]),
                "required": .array(["connection_id", "sql"]),
            ]),
            annotations: .init(title: "Explain query", readOnlyHint: true)
        ),
    ]
}
