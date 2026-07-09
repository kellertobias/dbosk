import DBCore
import Foundation
import Testing

@testable import Export

@Suite struct ResultExporterTests {
    private func makeExecution(
        columns: [ColumnMeta], chunks rowChunks: [[ResultRow]]
    ) -> QueryExecution {
        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
            .makeStream()
        for (index, rows) in rowChunks.enumerated() {
            continuation.yield(QueryResultChunk(
                rows: rows, isFinal: index == rowChunks.count - 1))
        }
        continuation.finish()
        return QueryExecution(columns: columns, chunks: stream, cancel: {})
    }

    private func tempFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-export-\(UUID().uuidString).\(ext)")
    }

    @Test func csvEscapingAndNulls() async throws {
        let columns = [
            ColumnMeta(name: "id", dbTypeName: "int"),
            ColumnMeta(name: "note, with comma", dbTypeName: "text"),
            ColumnMeta(name: "data", dbTypeName: "jsonb"),
        ]
        let rows = [
            ResultRow(id: 0, values: [
                .int(1),
                .string(#"say "hi"\#nsecond line"#),
                .document(["a": .int(1)]),
            ]),
            ResultRow(id: 1, values: [.int(2), .null, .string("plain")]),
        ]
        let url = tempFile("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ResultExporter().export(
            makeExecution(columns: columns, chunks: [rows]), format: .csv, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\r\n")
        #expect(lines[0] == #"id,"note, with comma",data"#)
        #expect(lines[1] == "1,\"say \"\"hi\"\"\nsecond line\",\"{\"\"a\"\":1}\"")
        #expect(lines[2] == "2,,plain")
    }

    @Test func jsonExportTypesRows() async throws {
        let columns = [
            ColumnMeta(name: "n", dbTypeName: "int"),
            ColumnMeta(name: "ok", dbTypeName: "bool"),
            ColumnMeta(name: "name", dbTypeName: "text"),
        ]
        let chunks = [
            [ResultRow(id: 0, values: [.int(1), .bool(true), .string("a")])],
            [ResultRow(id: 1, values: [.int(2), .bool(false), .null])],
        ]
        let url = tempFile("json")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ResultExporter().export(
            makeExecution(columns: columns, chunks: chunks), format: .json, to: url)

        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(parsed?.count == 2)
        #expect(parsed?[0]["n"] as? Int == 1)
        #expect(parsed?[0]["ok"] as? Bool == true)
        #expect(parsed?[1]["name"] is NSNull)
    }

    @Test func jsonExportDocumentShaped() async throws {
        let columns = [ColumnMeta(name: "document", dbTypeName: "document")]
        let rows = [
            ResultRow(id: 0, values: [
                .document(["_id": .string("x"), "nested": .array([.int(1)])])
            ])
        ]
        let url = tempFile("json")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ResultExporter().export(
            makeExecution(columns: columns, chunks: [rows]), format: .json, to: url)

        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        // Documents export as themselves, not wrapped in a "document" field.
        #expect(parsed?[0]["_id"] as? String == "x")
        #expect((parsed?[0]["nested"] as? [Int]) == [1])
    }

    @Test func reportsProgressAcrossChunks() async throws {
        let columns = [ColumnMeta(name: "n", dbTypeName: "int")]
        let chunks = (0..<5).map { chunk in
            (0..<100).map { ResultRow(id: chunk * 100 + $0, values: [.int(Int64($0))]) }
        }
        let url = tempFile("csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let progress = ProgressCollector()
        try await ResultExporter().export(
            makeExecution(columns: columns, chunks: chunks), format: .csv, to: url
        ) { progress.record($0.rowsWritten) }
        #expect(progress.values.last == 500)
        #expect(progress.values.count == 5)
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Int] = []

    func record(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }
}
