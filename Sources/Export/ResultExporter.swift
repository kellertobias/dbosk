import DBCore
import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case csv
    case json

    public var fileExtension: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
}

/// Streams query results to a file without buffering the whole result set.
/// Consumes a `QueryExecution`, so exports run against a fresh execution of
/// the query and work for arbitrarily large results.
public struct ResultExporter: Sendable {
    public struct Progress: Sendable {
        public let rowsWritten: Int
    }

    public init() {}

    /// Writes all chunks to `url`. Reports progress after each chunk.
    /// Honors Task cancellation (which also cancels the query execution).
    public func export(
        _ execution: QueryExecution,
        format: ExportFormat,
        to url: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var rowsWritten = 0
        switch format {
        case .csv:
            try handle.write(contentsOf: Data(csvHeader(execution.columns).utf8))
            for try await chunk in execution.chunks {
                var block = ""
                for row in chunk.rows {
                    block += csvLine(row.values)
                }
                try handle.write(contentsOf: Data(block.utf8))
                rowsWritten += chunk.rows.count
                onProgress?(Progress(rowsWritten: rowsWritten))
                try Task.checkCancellation()
            }

        case .json:
            // One JSON array; rows are objects keyed by column name, except
            // document-shaped results which export the documents themselves.
            let isDocumentShaped = execution.columns.count == 1
                && execution.columns.first?.dbTypeName == "document"
            try handle.write(contentsOf: Data("[\n".utf8))
            var first = true
            for try await chunk in execution.chunks {
                var block = ""
                for row in chunk.rows {
                    if !first { block += ",\n" }
                    first = false
                    block += jsonLine(
                        row.values,
                        columns: execution.columns,
                        documentShaped: isDocumentShaped)
                }
                try handle.write(contentsOf: Data(block.utf8))
                rowsWritten += chunk.rows.count
                onProgress?(Progress(rowsWritten: rowsWritten))
                try Task.checkCancellation()
            }
            try handle.write(contentsOf: Data("\n]\n".utf8))
        }
    }

    // MARK: CSV

    func csvHeader(_ columns: [ColumnMeta]) -> String {
        columns.map { csvEscape($0.name) }.joined(separator: ",") + "\r\n"
    }

    func csvLine(_ values: [DBValue]) -> String {
        values.map { value in
            switch value {
            case .null:
                return ""  // empty field, distinguishable from the string "NULL"
            case .document, .array:
                return csvEscape(value.jsonString(prettyPrinted: false))
            default:
                return csvEscape(value.displayString)
            }
        }.joined(separator: ",") + "\r\n"
    }

    func csvEscape(_ field: String) -> String {
        if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: JSON

    func jsonLine(
        _ values: [DBValue], columns: [ColumnMeta], documentShaped: Bool
    ) -> String {
        if documentShaped, let document = values.first {
            return document.jsonString(prettyPrinted: false)
        }
        var object: [String: DBValue] = [:]
        for (index, column) in columns.enumerated() where index < values.count {
            object[column.name] = values[index]
        }
        return DBValue.document(object).jsonString(prettyPrinted: false)
    }
}
