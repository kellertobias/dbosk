import DBCore
import Observation
import SwiftUI

// MARK: - Shared pieces

/// Executes a single DDL statement and tracks run state for a sheet.
@Observable
@MainActor
final class DDLRunner {
    var isRunning = false
    var errorMessage: String?

    func run(
        _ statement: String,
        using execute: @escaping (String) async throws -> Void,
        onSuccess: @escaping () -> Void
    ) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        Task {
            do {
                try await execute(statement)
                self.isRunning = false
                onSuccess()
            } catch {
                self.errorMessage = String(describing: error)
                self.isRunning = false
            }
        }
    }
}

/// Live SQL preview: the statement the builder generated, or why it can't be
/// built yet (validation message, secondary style).
struct SQLPreviewPane: View {
    let statement: Result<String, Error>

    var body: some View {
        Group {
            switch statement {
            case .success(let sql):
                ScrollView {
                    Text(sql)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            case .failure(let error):
                Label(String(describing: error), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
        }
        .frame(minHeight: 70, maxHeight: 160)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Common sheet frame: title, form fields, live SQL preview, error line,
/// Cancel/Execute buttons. Execute is enabled only when the builder produced
/// a statement.
struct DDLSheetScaffold<Fields: View>: View {
    let title: String
    let executeTitle: String
    let statement: Result<String, Error>
    let runner: DDLRunner
    let onExecute: (String) -> Void
    @ViewBuilder var fields: Fields

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            fields
            SQLPreviewPane(statement: statement)
            if let error = runner.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                if runner.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                DismissButton()
                Button(executeTitle) {
                    if case .success(let sql) = statement { onExecute(sql) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(runner.isRunning || !isValid)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
    }

    private var isValid: Bool {
        if case .success = statement { return true }
        return false
    }
}

private struct DismissButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
    }
}

/// Common column types offered in the type picker, per dialect. The field
/// stays free-text — these are just shortcuts.
enum DDLTypeSuggestions {
    static func types(for dialect: SQLDialect?) -> [String] {
        switch dialect {
        case .postgres:
            return [
                "text", "integer", "bigint", "boolean", "numeric",
                "double precision", "timestamptz", "date", "uuid", "jsonb", "bytea",
            ]
        case .mysql:
            return [
                "VARCHAR(255)", "TEXT", "INT", "BIGINT", "TINYINT(1)",
                "DECIMAL(10,2)", "DOUBLE", "DATETIME", "DATE", "JSON", "BLOB",
            ]
        case .sqlite:
            return ["TEXT", "INTEGER", "REAL", "NUMERIC", "BLOB"]
        case nil:
            return []
        }
    }
}

/// Free-text type field with a menu of per-dialect suggestions.
struct ColumnTypeField: View {
    let dialect: SQLDialect?
    @Binding var typeName: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("type", text: $typeName)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Menu {
                ForEach(DDLTypeSuggestions.types(for: dialect), id: \.self) { type in
                    Button(type) { typeName = type }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

// MARK: - Add column

struct AddColumnSheet: View {
    let browser: TableBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var typeName = ""
    @State private var isNullable = true
    @State private var defaultExpression = ""
    @State private var runner = DDLRunner()

    private var statement: Result<String, Error> {
        Result {
            guard let table = browser.table else {
                throw DBError(kind: .queryFailed, message: "No table selected")
            }
            return try DDLStatementBuilder.addColumn(
                ColumnDefinition(
                    name: name,
                    typeName: typeName,
                    isNullable: isNullable,
                    defaultExpression: defaultExpression.isEmpty ? nil : defaultExpression),
                to: table, for: browser.descriptor)
        }
    }

    var body: some View {
        DDLSheetScaffold(
            title: "Add Column",
            executeTitle: "Add Column",
            statement: statement,
            runner: runner,
            onExecute: { sql in
                runner.run(sql, using: browser.runDDL) {
                    dismiss()
                    browser.refreshAfterSchemaChange()
                }
            }
        ) {
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    TextField("column name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Type")
                    ColumnTypeField(
                        dialect: browser.descriptor.sqlDialect, typeName: $typeName)
                }
                GridRow {
                    Text("Default")
                    TextField("SQL expression, e.g. 0 or 'open'", text: $defaultExpression)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("")
                    Toggle("Allows NULL", isOn: $isNullable)
                }
            }
        }
    }
}

// MARK: - Rename column

struct RenameColumnSheet: View {
    let browser: TableBrowser
    let columnName: String
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var runner = DDLRunner()

    private var statement: Result<String, Error> {
        Result {
            guard let table = browser.table else {
                throw DBError(kind: .queryFailed, message: "No table selected")
            }
            let trimmed = newName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != columnName else {
                throw DBError(kind: .queryFailed, message: "Enter a new column name")
            }
            return DDLStatementBuilder.renameColumn(
                columnName, to: trimmed, in: table, for: browser.descriptor)
        }
    }

    var body: some View {
        DDLSheetScaffold(
            title: "Rename Column \"\(columnName)\"",
            executeTitle: "Rename",
            statement: statement,
            runner: runner,
            onExecute: { sql in
                runner.run(sql, using: browser.runDDL) {
                    dismiss()
                    browser.refreshAfterSchemaChange()
                }
            }
        ) {
            TextField("new name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onAppear { newName = columnName }
        }
    }
}

// MARK: - Create index

struct CreateIndexSheet: View {
    let browser: TableBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedColumns: [String] = []
    @State private var isUnique = false
    @State private var runner = DDLRunner()

    private var availableColumns: [String] {
        browser.structure?.columns.map(\.name) ?? []
    }

    private var suggestedName: String {
        let table = browser.table?.name ?? "table"
        let columns = selectedColumns.isEmpty ? "col" : selectedColumns.joined(separator: "_")
        return "idx_\(table)_\(columns)"
    }

    private var effectiveName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? suggestedName : trimmed
    }

    private var statement: Result<String, Error> {
        Result {
            guard let table = browser.table else {
                throw DBError(kind: .queryFailed, message: "No table selected")
            }
            return try DDLStatementBuilder.createIndex(
                named: effectiveName, on: table, columns: selectedColumns,
                unique: isUnique, for: browser.descriptor)
        }
    }

    var body: some View {
        DDLSheetScaffold(
            title: "Add Index",
            executeTitle: "Create Index",
            statement: statement,
            runner: runner,
            onExecute: { sql in
                runner.run(sql, using: browser.runDDL) {
                    dismiss()
                    browser.loadStructure(reload: true)
                }
            }
        ) {
            Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    TextField(suggestedName, text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Columns")
                    VStack(alignment: .leading, spacing: 4) {
                        // Selection order = index column order.
                        ForEach(availableColumns, id: \.self) { column in
                            Toggle(isOn: Binding(
                                get: { selectedColumns.contains(column) },
                                set: { isOn in
                                    if isOn {
                                        selectedColumns.append(column)
                                    } else {
                                        selectedColumns.removeAll { $0 == column }
                                    }
                                }
                            )) {
                                Text(column)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        if selectedColumns.count > 1 {
                            Text("Order: \(selectedColumns.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("")
                    Toggle("Unique", isOn: $isUnique)
                }
            }
        }
    }
}
