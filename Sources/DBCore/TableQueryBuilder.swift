import Foundation

/// Builds the table-browser query text for a driver dialect. Kept in DBCore
/// (rather than the UI layer) so it is unit-testable.
public enum TableQueryBuilder {
    public struct Request {
        public var table: Namespace
        /// Column names to project; empty = all. Order should follow the
        /// table's column order, not selection order.
        public var columns: [String]
        /// SQL condition or Mongo JSON filter, already trimmed.
        public var filter: String
        public var offset: Int
        public var limit: Int

        public init(
            table: Namespace, columns: [String] = [], filter: String = "",
            offset: Int = 0, limit: Int = 100
        ) {
            self.table = table
            self.columns = columns
            self.filter = filter
            self.offset = offset
            self.limit = limit
        }
    }

    public static func build(_ request: Request, for descriptor: DriverDescriptor) -> String {
        let limit = max(request.limit, 1)
        let offset = max(request.offset, 0)
        let filter = request.filter.trimmingCharacters(in: .whitespacesAndNewlines)

        switch descriptor.queryLanguage {
        case .mongo:
            var query = "db.\(request.table.path.joined(separator: ".")).find(\(filter.isEmpty ? "{}" : filter))"
            if offset > 0 { query += ".skip(\(offset))" }
            query += ".limit(\(limit))"
            return query
        case .redis:
            // Filter field holds a key pattern; limit caps the number of keys.
            let pattern = filter.isEmpty ? "*" : filter
            return "SCAN 0 MATCH \(pattern) COUNT \(limit)"
        case .partiql:
            // DynamoDB PartiQL has no LIMIT/OFFSET clauses; the driver pages
            // via the API instead.
            let target = descriptor.quoted(request.table.path.joined(separator: "."))
            var sql = "SELECT * FROM \(target)"
            if !filter.isEmpty { sql += " WHERE \(filter)" }
            return sql
        case .sql:
            break
        }

        let target = request.table.path
            .map { descriptor.quoted($0) }
            .joined(separator: ".")
        let columns = request.columns.isEmpty
            ? "*"
            : request.columns.map { descriptor.quoted($0) }.joined(separator: ", ")
        var sql = "SELECT \(columns) FROM \(target)"
        if !filter.isEmpty {
            sql += " WHERE \(filter)"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return sql
    }
}
