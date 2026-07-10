import DBCore
import SwiftUI

/// Structure mode of the table browser: column definitions and indexes,
/// with alter-table / index DDL entry points for drivers that support it.
struct TableStructureView: View {
    @Bindable var browser: TableBrowser

    private enum ActiveSheet: Identifiable {
        case addColumn
        case renameColumn(String)
        case createIndex

        var id: String {
            switch self {
            case .addColumn: return "addColumn"
            case .renameColumn(let name): return "rename:\(name)"
            case .createIndex: return "createIndex"
            }
        }
    }

    /// Destructive DDL awaiting confirmation (drop column / drop index).
    private struct DropRequest: Identifiable {
        let id = UUID()
        let title: String
        let sql: String
        let refreshesColumns: Bool
    }

    @State private var activeSheet: ActiveSheet?
    @State private var dropRequest: DropRequest?
    @State private var dropRunner = DDLRunner()

    /// DDL entry points only for real tables on DDL-capable drivers.
    private var allowsDDL: Bool {
        browser.descriptor.supportsDDL && browser.table?.kind == .table(.table)
    }

    var body: some View {
        Group {
            if browser.isLoadingStructure && browser.structure == nil {
                ProgressView("Loading structure…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = browser.structureError {
                ContentUnavailableView {
                    Label("Could Not Load Structure", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { browser.loadStructure(reload: true) }
                }
            } else if let structure = browser.structure {
                structureContent(structure)
            } else {
                Color.clear
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addColumn:
                AddColumnSheet(browser: browser)
            case .renameColumn(let name):
                RenameColumnSheet(browser: browser, columnName: name)
            case .createIndex:
                CreateIndexSheet(browser: browser)
            }
        }
        .confirmationDialog(
            dropRequest?.title ?? "",
            isPresented: Binding(
                get: { dropRequest != nil },
                set: { if !$0 { dropRequest = nil } })
        ) {
            Button("Execute", role: .destructive) {
                guard let request = dropRequest else { return }
                dropRequest = nil
                dropRunner.run(request.sql, using: browser.runDDL) {
                    if request.refreshesColumns {
                        browser.refreshAfterSchemaChange()
                    } else {
                        browser.loadStructure(reload: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) { dropRequest = nil }
        } message: {
            Text(dropRequest?.sql ?? "")
        }
    }

    private func structureContent(_ structure: TableStructure) -> some View {
        VStack(spacing: 0) {
            if let error = dropRunner.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.08))
            }
            VSplitView {
                columnsTable(structure.columns)
                    .frame(minHeight: 120)
                indexesSection(structure.indexes)
                    .frame(minHeight: 100)
            }
        }
    }

    private func columnsTable(_ columns: [ColumnDetail]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Columns", count: columns.count) {
                if allowsDDL {
                    Button("Add Column…") { activeSheet = .addColumn }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            columnsTableContent(columns)
        }
    }

    private func columnsTableContent(_ columns: [ColumnDetail]) -> some View {
        Table(columns) {
                TableColumn("") { column in
                    if column.isPrimaryKey {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.orange)
                            .help("Primary key")
                    }
                }
                .width(20)
                TableColumn("Name") { column in
                    Text(column.name)
                        .fontWeight(column.isPrimaryKey ? .semibold : .regular)
                        .textSelection(.enabled)
                }
                TableColumn("Type") { column in
                    Text(column.dbTypeName)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                TableColumn("Nullable") { column in
                    Text(column.isNullable ? "NULL" : "NOT NULL")
                        .foregroundStyle(column.isNullable ? .secondary : .primary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Default") { column in
                    Text(column.defaultValue ?? "")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
        }
        .contextMenu(forSelectionType: ColumnDetail.ID.self) { names in
            if allowsDDL, let name = names.first {
                Button("Rename Column…") { activeSheet = .renameColumn(name) }
                Button("Drop Column", role: .destructive) {
                    guard let table = browser.table else { return }
                    dropRequest = DropRequest(
                        title: "Drop column \"\(name)\"?",
                        sql: DDLStatementBuilder.dropColumn(
                            name, from: table, for: browser.descriptor),
                        refreshesColumns: true)
                }
            }
        }
    }

    private func indexesSection(_ indexes: [IndexInfo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Indexes", count: indexes.count) {
                if allowsDDL {
                    Button("Add Index…") { activeSheet = .createIndex }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if indexes.isEmpty {
                Text("No indexes")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(indexes) {
                    TableColumn("") { index in
                        if index.isPrimary {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.orange)
                                .help("Primary key")
                        }
                    }
                    .width(20)
                    TableColumn("Name") { index in
                        Text(index.name)
                            .fontWeight(index.isPrimary ? .semibold : .regular)
                            .textSelection(.enabled)
                    }
                    TableColumn("Columns") { index in
                        Text(index.columns.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    TableColumn("Unique") { index in
                        if index.isUnique {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 50, ideal: 60)
                    TableColumn("Type") { index in
                        Text(index.method ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 90)
                }
                .contextMenu(forSelectionType: IndexInfo.ID.self) { names in
                    if allowsDDL, let name = names.first,
                       browser.structure?.indexes
                           .first(where: { $0.name == name })?.isPrimary != true {
                        Button("Drop Index", role: .destructive) {
                            guard let table = browser.table,
                                  let sql = try? DDLStatementBuilder.dropIndex(
                                      named: name, on: table, for: browser.descriptor)
                            else { return }
                            dropRequest = DropRequest(
                                title: "Drop index \"\(name)\"?",
                                sql: sql,
                                refreshesColumns: false)
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(
        _ title: String, count: Int,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
