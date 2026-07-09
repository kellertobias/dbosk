import DBCore
import SwiftUI

/// Full Table mode: browse one table with column selection, WHERE filter,
/// and limit/offset paging. Builds a SELECT and reuses the streaming runner.
struct TableModeView: View {
    @Bindable var browser: TableBrowser
    var session: ConnectionSession?

    var body: some View {
        if browser.table == nil {
            ContentUnavailableView(
                "No Table Selected",
                systemImage: "tablecells",
                description: Text("Select a table in the sidebar."))
        } else {
            VStack(spacing: 0) {
                if browser.displayMode == .data {
                    controls
                    Divider()
                    ResultsArea(
                        columns: browser.resultTab.columns,
                        rows: browser.resultTab.rows,
                        version: browser.resultTab.resultVersion)
                    statusBar
                } else {
                    structureHeader
                    Divider()
                    TableStructureView(browser: browser)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Spacer()
                    modePicker
                    if browser.displayMode == .data {
                        ExportMenu(tab: browser.resultTab)
                        if browser.resultTab.runState == .running
                            || browser.resultTab.runState == .streaming {
                            Button {
                                browser.resultTab.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                        } else {
                            Button {
                                browser.load()
                            } label: {
                                Label("Load", systemImage: "play.fill")
                            }
                            .keyboardShortcut(.return, modifiers: .command)
                        }
                    } else {
                        Button {
                            browser.loadStructure(reload: true)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(browser.isLoadingStructure)
                        .help("Reload the table structure")
                    }
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { browser.displayMode },
            set: { browser.setDisplayMode($0) }
        )) {
            ForEach(TableBrowser.DisplayMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .help("Switch between table data and structure")
    }

    /// Structure mode keeps the same table title/note header as data mode,
    /// without the filter and paging controls.
    private var structureHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(browser.table?.path.joined(separator: ".") ?? "",
                      systemImage: "tablecells")
                    .font(.headline)
                Spacer()
                if browser.isLoadingStructure {
                    ProgressView().controlSize(.small)
                }
            }
            if let session, let table = browser.table,
               let note = session.note(for: table) {
                Label(note, systemImage: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(browser.table?.path.joined(separator: ".") ?? "",
                      systemImage: "tablecells")
                    .font(.headline)
                Spacer()
                if browser.isLoadingColumns {
                    ProgressView().controlSize(.small)
                }
                // Column projection is SQL-only in v1.
                if browser.descriptor.queryLanguage != .mongo {
                    columnsMenu
                        .disabled(browser.isLoadingColumns)
                }
            }
            if let session, let table = browser.table,
               let note = session.note(for: table) {
                Label(note, systemImage: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Text(browser.descriptor.queryLanguage == .mongo ? "FILTER" : "WHERE")
                    .font(.caption).foregroundStyle(.secondary)
                TextField(
                    browser.descriptor.queryLanguage == .mongo
                        ? #"JSON filter, e.g. {"status": "active"}"#
                        : "condition, e.g. status = 'active'",
                    text: $browser.whereClause)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    browser.offset = 0
                    browser.load()
                }
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Start").font(.caption).foregroundStyle(.secondary)
                    TextField("0", value: $browser.offset, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { browser.load() }
                }
                HStack(spacing: 4) {
                    Text("Rows").font(.caption).foregroundStyle(.secondary)
                    TextField("100", value: $browser.limit, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            browser.offset = 0
                            browser.load()
                        }
                }
                Button {
                    browser.previousPage()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(browser.offset == 0)
                .help("Previous page")
                Button {
                    browser.nextPage()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next page")
                Spacer()
            }
        }
        .padding(10)
    }

    private var columnsMenu: some View {
        Menu {
            Button("All Columns") {
                browser.selectedColumns = []
                browser.load()
            }
            Divider()
            ForEach(browser.availableColumns, id: \.name) { column in
                Toggle(isOn: Binding(
                    get: {
                        browser.selectedColumns.isEmpty
                            || browser.selectedColumns.contains(column.name)
                    },
                    set: { _ in
                        // Deselecting from "all" state keeps the others selected.
                        if browser.selectedColumns.isEmpty {
                            browser.selectedColumns = Set(
                                browser.availableColumns.map(\.name))
                        }
                        browser.toggleColumn(column.name)
                        browser.load()
                    }
                )) {
                    Text("\(column.name)  –  \(column.dbTypeName)")
                }
            }
        } label: {
            Label(columnsLabel, systemImage: "slider.horizontal.3")
        }
        .frame(maxWidth: 220)
    }

    private var columnsLabel: String {
        if browser.selectedColumns.isEmpty {
            return "All columns"
        }
        return "\(browser.selectedColumns.count) of \(browser.availableColumns.count) columns"
    }

    private var statusBar: some View {
        HStack {
            if let error = browser.columnsError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            switch browser.resultTab.runState {
            case .idle:
                Text("Ready")
            case .running, .streaming:
                ProgressView().controlSize(.small)
                Text("Loading…")
            case .done(let count, let elapsed):
                Text("Rows \(browser.offset)–\(browser.offset + count) · \(String(format: "%.2f", elapsed))s")
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                Text("Cancelled").foregroundStyle(.orange)
            }
            Spacer()
            ExportStatusView(tab: browser.resultTab)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
