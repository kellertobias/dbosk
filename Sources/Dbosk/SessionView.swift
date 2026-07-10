import AppKit
import Connections
import DBCore
import Export
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var session: ConnectionSession

    var body: some View {
        VStack(spacing: 0) {
            // Always-visible environment stripe (e.g. red = production).
            if let label = appModel.label(for: session.profile) {
                Rectangle()
                    .fill(label.colorTag.color)
                    .frame(height: 3)
            }
            NavigationSplitView {
                SidebarView(session: session)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240)
                    // Attached to the sidebar column so the title renders in
                    // the leftmost toolbar section, next to the sidebar toggle.
                    .toolbar {
                        if #available(macOS 26.0, *) {
                            // Opt out of the Liquid Glass toolbar background so
                            // the title and badge read as plain content, not
                            // buttons.
                            ToolbarItem(placement: .navigation) { titleView }
                                .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .navigation) { titleView }
                        }
                    }
            } detail: {
                VStack(spacing: 0) {
                    TabBarView(session: session)
                    Divider()
                    tabContent
                }
            }
        }
        .navigationTitle(session.profile.name)
        // Keep navigationTitle for window identity, but hide its visible item so
        // it doesn't render "Test" separately from our leading title view.
        .hidingWindowTitle()
        .task { await session.loadRoot() }
        // Closing the window ends the session — no separate disconnect control.
        .onDisappear { appModel.disconnect(profileID: session.profile.id) }
    }

    /// Leading toolbar title: "Group: Name" on one line, with the label badge
    /// stacked beneath it.
    private var titleView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(toolbarTitle)
                .font(.headline)
                .lineLimit(1)
            if let label = appModel.label(for: session.profile) {
                LabelBadge(label: label)
            }
        }
    }

    private var toolbarTitle: String {
        if let group = session.profile.groupName, !group.isEmpty {
            return "\(group): \(session.profile.name)"
        }
        return session.profile.name
    }

    @ViewBuilder
    private var tabContent: some View {
        if let tab = session.selectedTab {
            switch tab.content {
            case .query(let queryTab):
                QueryView(tab: queryTab, session: session)
            case .table(let browser):
                TableModeView(browser: browser, session: session)
            }
        } else {
            ContentUnavailableView(
                "No Tab Open",
                systemImage: "tablecells",
                description: Text(
                    "Click a table in the sidebar, or the SQL button on a schema."))
        }
    }
}

private extension View {
    /// Removes the default window-title toolbar item (macOS 15+) while leaving
    /// `navigationTitle` intact for window identity. No-op on older systems.
    @ViewBuilder
    func hidingWindowTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

// MARK: - Tab bar

struct TabBarView: View {
    @Bindable var session: ConnectionSession

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 4)
            }
            Button {
                session.openQueryTab()
            } label: {
                Label("New Query", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("New query tab")
            .padding(.trailing, 6)
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func tabButton(_ tab: WorkTab) -> some View {
        let isSelected = session.selectedTabID == tab.id
        return HStack(spacing: 4) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
            Button {
                session.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTabID = tab.id }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    /// Table pending a drop confirmation, with its sidebar parent for reload.
    struct DropTableRequest: Identifiable {
        let id = UUID()
        let table: DBCore.Namespace
        let parent: DBCore.Namespace?
        let sql: String
    }

    @Bindable var session: ConnectionSession
    @State private var noteTarget: DBCore.Namespace?
    @State private var groupTarget: DBCore.Namespace?
    @State private var newGroupName = ""
    @State private var renameTarget: SavedQuery?
    @State private var renameText = ""
    @State private var expandedIDs: Set<String> = []
    @State private var dropTableRequest: DropTableRequest?

    var body: some View {
        List {
            if let error = session.sidebarError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            if !session.metadata.savedQueries.isEmpty {
                Section("Saved Queries") {
                    ForEach(session.metadata.savedQueries) { saved in
                        savedQueryRow(saved)
                    }
                }
            }
            Section {
                ForEach(session.rootNamespaces.map {
                    SidebarNode(kind: .namespace($0, parent: nil), session: session)
                }) { node in
                    outlineRow(node)
                }
            } header: {
                HStack(spacing: 8) {
                    Text(session.profile.database ?? "Objects")
                    Spacer()
                    if session.editingVisibility {
                        Button("All") { session.setAllTablesVisible(true) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Select all tables")
                        Button("None") { session.setAllTablesVisible(false) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Deselect all tables")
                        Button("Done") { session.editingVisibility = false }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                    } else {
                        if !session.metadata.tables.filter(\.value.hidden).isEmpty {
                            Button {
                                session.showHiddenTables.toggle()
                            } label: {
                                Image(systemName: session.showHiddenTables
                                    ? "eye" : "eye.slash")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help(session.showHiddenTables
                                ? "Showing hidden tables" : "Show hidden tables")
                        }
                        Button {
                            session.editingVisibility = true
                        } label: {
                            Image(systemName: "checklist")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Choose which tables to show")
                    }
                }
                .padding(.trailing, 12)
            }
        }
        // Give the database name / table-visibility controls room below the
        // window chrome instead of crowding the top edge. Fixed padding (not
        // contentMargins) so the offset can't scroll away when the list is
        // clicked, which made the sidebar jump vertically.
        .padding(.top, 16)
        .sheet(item: $noteTarget) { namespace in
            NoteEditorView(session: session, namespace: namespace)
        }
        .alert("New Group", isPresented: groupAlertShown) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) { groupTarget = nil }
            Button("Create") {
                if let target = groupTarget, !newGroupName.isEmpty {
                    session.setGroup(newGroupName, for: target)
                }
                groupTarget = nil
                newGroupName = ""
            }
        } message: {
            Text("Group tables within their schema in the sidebar.")
        }
        .alert("Rename Query", isPresented: renameAlertShown) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    session.renameSavedQuery(target, to: renameText)
                }
                renameTarget = nil
            }
        }
        .confirmationDialog(
            "Drop table \"\(dropTableRequest?.table.name ?? "")\"?",
            isPresented: Binding(
                get: { dropTableRequest != nil },
                set: { if !$0 { dropTableRequest = nil } })
        ) {
            Button("Drop Table", role: .destructive) {
                guard let request = dropTableRequest else { return }
                dropTableRequest = nil
                Task {
                    do {
                        try await session.runDDL(request.sql)
                        session.closeTabs(showing: request.table)
                        if let parent = request.parent {
                            await session.reloadChildren(of: parent)
                        } else {
                            await session.loadRoot()
                        }
                    } catch {
                        session.sidebarError = String(describing: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) { dropTableRequest = nil }
        } message: {
            Text("\(dropTableRequest?.sql ?? "")\n\nThis permanently deletes the table and its data.")
        }
    }

    private var renameAlertShown: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }

    private var groupAlertShown: Binding<Bool> {
        Binding(
            get: { groupTarget != nil },
            set: { if !$0 { groupTarget = nil } })
    }

    private func savedQueryRow(_ saved: SavedQuery) -> some View {
        Label(saved.name, systemImage: "bookmark")
            .contentShape(Rectangle())
            .onTapGesture {
                session.openQueryTab(saved: saved)
            }
            .help(saved.text)
            .contextMenu {
                Button("Open") { session.openQueryTab(saved: saved) }
                Button("Run") {
                    session.openQueryTab(saved: saved, runImmediately: true)
                }
                Divider()
                Button("Rename…") {
                    renameText = saved.name
                    renameTarget = saved
                }
                Button("Delete", role: .destructive) {
                    session.deleteSavedQuery(saved)
                }
            }
    }

    /// Whether this node expands/collapses on click rather than opening.
    private func isExpandableNode(_ node: SidebarNode) -> Bool {
        switch node.kind {
        case .group:
            return true
        case .namespace(let namespace, _):
            return namespace.isExpandable
        }
    }

    private func outlineRow(_ node: SidebarNode) -> AnyView {
        if isExpandableNode(node) {
            return AnyView(
                DisclosureGroup(isExpanded: expandedBinding(for: node.id)) {
                    ForEach(node.children ?? []) { child in
                        outlineRow(child)
                    }
                } label: {
                    row(for: node)
                        .onTapGesture { toggleExpanded(node.id) }
                })
        } else {
            return AnyView(row(for: node))
        }
    }

    private func expandedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedIDs.insert(id)
                } else {
                    expandedIDs.remove(id)
                }
            })
    }

    private func toggleExpanded(_ id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    @ViewBuilder
    private func row(for node: SidebarNode) -> some View {
        switch node.kind {
        case .group(let name, let parent):
            HStack(spacing: 4) {
                if session.editingVisibility {
                    groupCheckbox(name: name, parent: parent)
                }
                Label(name, systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        case .namespace(let namespace, let parent):
            namespaceRow(namespace, parent: parent)
        }
    }

    /// Checkbox for a whole group: checked / unchecked / mixed.
    private func groupCheckbox(name: String, parent: DBCore.Namespace) -> some View {
        let tables = session.allTables(in: parent)
            .filter { session.group(for: $0) == name }
        let visibleCount = tables.filter { !session.isHidden($0) }.count
        let symbol = visibleCount == tables.count
            ? "checkmark.square.fill"
            : (visibleCount == 0 ? "square" : "minus.square.fill")
        return Button {
            session.setGroupVisible(visibleCount != tables.count, group: name, in: parent)
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(visibleCount == 0 ? .secondary : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .help("Show or hide all tables in \(name)")
    }

    private func namespaceRow(
        _ namespace: DBCore.Namespace, parent: DBCore.Namespace?
    ) -> some View {
        let isHidden = session.isHidden(namespace)
        let note = session.note(for: namespace)
        return HStack(spacing: 4) {
            if session.editingVisibility, namespace.kind.isTable {
                Image(systemName: isHidden ? "square" : "checkmark.square.fill")
                    .foregroundStyle(isHidden ? .secondary : Color.accentColor)
            }
            Label(namespace.name, systemImage: SidebarNode.icon(for: namespace))
                .foregroundStyle(isHidden ? .tertiary : .primary)
            if note != nil {
                Image(systemName: "note.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(note ?? "")
        .contentShape(Rectangle())
        .modifier(TableTapModifier(
            isTable: namespace.kind.isTable,
            action: {
                if session.editingVisibility {
                    session.setHidden(!isHidden, for: namespace)
                } else {
                    session.openTable(namespace)
                }
            }))
        .contextMenu {
            if case .table = namespace.kind {
                tableContextMenu(namespace, parent: parent)
            } else {
                Button("New Query") { session.openQueryTab() }
                Button("Show All Tables") { session.unhideAll(in: namespace) }
            }
        }
    }

    @ViewBuilder
    private func tableContextMenu(
        _ namespace: DBCore.Namespace, parent: DBCore.Namespace?
    ) -> some View {
        Button("Open Table") { session.openTable(namespace) }
        Button("Show Structure") { session.openTable(namespace, mode: .structure) }
        Button("Query Table") {
            session.openQueryTab(
                initialSQL: SidebarNode.defaultQuery(for: namespace, in: session),
                runImmediately: true)
        }
        Divider()
        Button(session.note(for: namespace) == nil ? "Add Note…" : "Edit Note…") {
            noteTarget = namespace
        }
        Menu("Group") {
            ForEach(session.metadata.groupNames, id: \.self) { group in
                Button {
                    session.setGroup(group, for: namespace)
                } label: {
                    if session.group(for: namespace) == group {
                        Label(group, systemImage: "checkmark")
                    } else {
                        Text(group)
                    }
                }
            }
            if !session.metadata.groupNames.isEmpty { Divider() }
            Button("New Group…") { groupTarget = namespace }
            if session.group(for: namespace) != nil {
                Button("Remove from Group") { session.setGroup(nil, for: namespace) }
            }
        }
        Divider()
        Button(session.isHidden(namespace) ? "Unhide Table" : "Hide Table") {
            session.setHidden(!session.isHidden(namespace), for: namespace)
        }
        Button("Choose Visible Tables…") { session.editingVisibility = true }
        if let parent {
            Button("Show All Tables") { session.unhideAll(in: parent) }
        }
        if session.descriptor.supportsDDL, namespace.kind == .table(.table) {
            Divider()
            Button("Drop Table…", role: .destructive) {
                dropTableRequest = DropTableRequest(
                    table: namespace,
                    parent: parent,
                    sql: DDLStatementBuilder.dropTable(namespace, for: session.descriptor))
            }
        }
    }
}

/// Sidebar tree node: a real namespace or a user-defined table group.
@MainActor
struct SidebarNode: @MainActor Identifiable {
    enum Kind {
        case namespace(DBCore.Namespace, parent: DBCore.Namespace?)
        case group(String, parent: DBCore.Namespace)
    }

    let kind: Kind
    let session: ConnectionSession

    var id: String {
        switch kind {
        case .namespace(let namespace, _): return namespace.id
        case .group(let name, let parent): return parent.id + "#group:" + name
        }
    }

    var children: [SidebarNode]? {
        switch kind {
        case .group(let name, let parent):
            return visibleTables(of: parent)
                .filter { session.group(for: $0) == name }
                .map { SidebarNode(kind: .namespace($0, parent: parent), session: session) }
        case .namespace(let namespace, _):
            guard namespace.isExpandable else { return nil }
            guard let loaded = session.children[namespace.id] else {
                // Trigger lazy load; OutlineGroup re-renders when children update.
                Task { await session.loadChildren(of: namespace) }
                return []
            }
            var nodes: [SidebarNode] = loaded
                .filter { !$0.kind.isTable }
                .map { SidebarNode(kind: .namespace($0, parent: namespace), session: session) }
            let tables = visibleTables(of: namespace)
            let groups = Set(tables.compactMap { session.group(for: $0) }).sorted()
            nodes += groups.map {
                SidebarNode(kind: .group($0, parent: namespace), session: session)
            }
            nodes += tables
                .filter { session.group(for: $0) == nil }
                .map { SidebarNode(kind: .namespace($0, parent: namespace), session: session) }
            return nodes
        }
    }

    private func visibleTables(of parent: DBCore.Namespace) -> [DBCore.Namespace] {
        (session.children[parent.id] ?? [])
            .filter(\.kind.isTable)
            .filter {
                session.editingVisibility || session.showHiddenTables
                    || !session.isHidden($0)
            }
    }

    static func icon(for namespace: DBCore.Namespace) -> String {
        switch namespace.kind {
        case .database: return "cylinder"
        case .schema: return "folder"
        case .table(.view): return "eye"
        case .table(.collection): return "doc.text"
        case .table: return "tablecells"
        }
    }

    static func defaultQuery(
        for namespace: DBCore.Namespace, in session: ConnectionSession
    ) -> String {
        let descriptor = session.descriptor
        if descriptor.queryLanguage == .mongo {
            return "db.\(namespace.path.joined(separator: ".")).find({}).limit(100)"
        }
        let path = namespace.path.map { descriptor.quoted($0) }.joined(separator: ".")
        return "SELECT * FROM \(path) LIMIT 100;"
    }
}

extension DBCore.Namespace.Kind {
    var isTable: Bool {
        if case .table = self { return true }
        return false
    }
}

/// Attaches a tap gesture only for table rows, letting non-table (expandable)
/// namespace rows fall through to the enclosing DisclosureGroup's tap-to-expand.
private struct TableTapModifier: ViewModifier {
    let isTable: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isTable {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

// MARK: - Note editor

struct NoteEditorView: View {
    let session: ConnectionSession
    let namespace: DBCore.Namespace
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(namespace.path.joined(separator: "."), systemImage: "note.text")
                .font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                if session.note(for: namespace) != nil {
                    Button("Remove Note", role: .destructive) {
                        session.setNote(nil, for: namespace)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    session.setNote(text, for: namespace)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { text = session.note(for: namespace) ?? "" }
    }
}

/// Picks the right renderer: document-shaped results (Mongo) get the
/// two-column list + tree view, everything else the flat table.
struct ResultsArea: View {
    let columns: [ColumnMeta]
    let rows: [ResultRow]
    let version: Int
    var editing: ResultsTableView.EditingConfig?

    var body: some View {
        if columns.count == 1, columns[0].dbTypeName == "document" {
            DocumentResultsView(rows: rows)
        } else {
            ResultsTableView(
                columns: columns, rows: rows, version: version, editing: editing)
        }
    }
}

// MARK: - Query view

struct QueryView: View {
    @Bindable var tab: QueryTab
    let session: ConnectionSession
    @State private var savingQuery = false
    @State private var savedQueryName = ""

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                SyntaxTextEditor(text: $tab.queryText, language: tab.language)
                    .frame(minHeight: 80)
                statusBar
            }
            ResultsArea(columns: tab.columns, rows: tab.rows, version: tab.resultVersion)
                .frame(minHeight: 120)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Spacer()
                HistoryMenu(tab: tab, session: session)
                saveControl
                ExportMenu(tab: tab)
                if tab.runState == .running || tab.runState == .streaming {
                    Button {
                        tab.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        tab.run()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .alert("Save Query", isPresented: $savingQuery) {
            TextField("Name", text: $savedQueryName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = savedQueryName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                tab.savedQuery = session.saveQuery(named: name, text: tab.queryText)
            }
        } message: {
            Text("Saved queries appear in the sidebar for this connection.")
        }
    }

    /// A single "Save Query" button when unlinked; a menu offering
    /// update-in-place or save-as-new once the tab is tied to a saved query.
    @ViewBuilder
    private var saveControl: some View {
        let isEmpty = tab.queryText.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
        if let saved = tab.savedQuery {
            Menu {
                Button("Update “\(saved.name)”") {
                    tab.savedQuery = session.updateSavedQuery(saved, text: tab.queryText)
                }
                .disabled(!tab.hasUnsavedChanges)
                Button("Save as New…") {
                    savedQueryName = ""
                    savingQuery = true
                }
            } label: {
                Label("Save Query", systemImage: "bookmark")
            }
            .menuIndicator(.visible)
            .disabled(isEmpty)
            .help("Update the saved query or save a copy")
        } else {
            Button {
                savedQueryName = ""
                savingQuery = true
            } label: {
                Label("Save Query", systemImage: "bookmark")
            }
            .disabled(isEmpty)
            .help("Save this query to the sidebar")
        }
    }

    private var statusBar: some View {
        HStack {
            switch tab.runState {
            case .idle:
                Text("Ready")
            case .running:
                ProgressView().controlSize(.small)
                Text("Running…")
            case .streaming:
                ProgressView().controlSize(.small)
                Text("Streaming… \(tab.rows.count) rows")
            case .done(let count, let elapsed):
                Text("\(count) rows in \(String(format: "%.2f", elapsed))s")
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                Text("Cancelled").foregroundStyle(.orange)
            }
            Spacer()
            ExportStatusView(tab: tab)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

// MARK: - Query history

struct HistoryMenu: View {
    @Bindable var tab: QueryTab
    let session: ConnectionSession

    var body: some View {
        Menu {
            if session.metadata.history.isEmpty {
                Text("No queries yet")
            }
            ForEach(session.metadata.history.prefix(25)) { entry in
                Button {
                    tab.queryText = entry.text
                } label: {
                    Label {
                        Text(title(for: entry))
                    } icon: {
                        Image(systemName: entry.succeeded
                            ? "clock" : "exclamationmark.triangle")
                    }
                }
                .help(entry.text)
            }
            if !session.metadata.history.isEmpty {
                Divider()
                Button("Clear History", role: .destructive) {
                    session.clearHistory()
                }
            }
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
        }
        .help("Recent queries on this connection")
    }

    private func title(for entry: QueryHistoryEntry) -> String {
        let compact = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(
                of: #"\s+"#, with: " ", options: .regularExpression)
        let text = compact.count > 60
            ? String(compact.prefix(60)) + "…" : compact
        let when = entry.executedAt.formatted(
            .relative(presentation: .named, unitsStyle: .narrow))
        return "\(text)   ·   \(when)"
    }
}

// MARK: - Export UI

struct ExportMenu: View {
    let tab: QueryTab

    var body: some View {
        Menu {
            Button("Export as CSV…") { save(.csv) }
            Button("Export as JSON…") { save(.json) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(tab.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Re-runs the query and streams the full result to a file")
    }

    private func save(_ format: Export.ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "results.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            tab.export(format: format, to: url)
        }
    }
}

struct ExportStatusView: View {
    let tab: QueryTab

    var body: some View {
        switch tab.exportState {
        case .idle:
            EmptyView()
        case .exporting(let rows):
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Exporting… \(rows) rows")
            }
        case .done(let url):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle")
            }
            .buttonStyle(.link)
            .font(.caption)
        case .failed(let message):
            Text("Export failed: \(message)")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}
