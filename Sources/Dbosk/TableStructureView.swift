import DBCore
import SwiftUI

/// Structure mode of the table browser: column definitions and indexes.
struct TableStructureView: View {
    @Bindable var browser: TableBrowser

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
    }

    private func structureContent(_ structure: TableStructure) -> some View {
        VSplitView {
            columnsTable(structure.columns)
                .frame(minHeight: 120)
            indexesSection(structure.indexes)
                .frame(minHeight: 100)
        }
    }

    private func columnsTable(_ columns: [ColumnDetail]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Columns", count: columns.count)
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
        }
    }

    private func indexesSection(_ indexes: [IndexInfo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Indexes", count: indexes.count)
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
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
