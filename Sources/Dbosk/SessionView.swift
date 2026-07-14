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
            // Always-visible environment stripe (e.g. red = production);
            // neutral gray when the connection has no label.
            Rectangle()
                .fill(appModel.label(for: session.profile)?.colorTag.color ?? .unlabeledStripe)
                .frame(height: 3)
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
    @State private var createTableParent: DBCore.Namespace?

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
                let rows = session.sidebarRows(expanded: expandedIDs)
                // Everything at the root is hidden (drivers that default-hide
                // their roots start this way on purpose): point at the
                // visibility editor instead of showing an empty list. Other
                // drivers keep a plain empty sidebar.
                if rows.isEmpty && !session.rootNamespaces.isEmpty
                    && session.descriptor.rootNamespacesDefaultHidden {
                    allHiddenPlaceholder
                } else {
                    ForEach(rows) { row in
                        SidebarOutlineRow(
                            row: row,
                            session: session,
                            isExpanded: row.isExpandable && expandedIDs.contains(row.id),
                            onToggleExpand: { toggleExpanded(row.id) },
                            noteTarget: $noteTarget,
                            groupTarget: $groupTarget,
                            dropTableRequest: $dropTableRequest,
                            createTableParent: $createTableParent)
                            .equatable()
                    }
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
                        if session.metadata.tables.contains(where: \.value.hidden) {
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
        .sheet(item: $createTableParent) { parent in
            CreateTableSheet(session: session, parent: parent)
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

    /// Shown when every root namespace is hidden and the sidebar is not in
    /// visibility-edit mode. Edit mode lists all rows (including hidden
    /// ones) with checkboxes, so entering it is all the button needs to do.
    private var allHiddenPlaceholder: some View {
        VStack(spacing: 10) {
            Text("No databases selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Databases…") { session.editingVisibility = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
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

    private func toggleExpanded(_ id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

}

/// One flattened outline row: manual indentation and chevron instead of
/// nested DisclosureGroups (whose diffing cost made large sidebars lag).
///
/// Renders purely from `row` + `isExpanded` — session state is only read
/// inside click actions and menu bodies — so `.equatable()` can skip every
/// row whose data did not change when the sidebar updates.
private struct SidebarOutlineRow: View, @MainActor Equatable {
    let row: SidebarRow
    let session: ConnectionSession
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    @Binding var noteTarget: DBCore.Namespace?
    @Binding var groupTarget: DBCore.Namespace?
    @Binding var dropTableRequest: SidebarView.DropTableRequest?
    @Binding var createTableParent: DBCore.Namespace?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        switch row.kind {
        case .group(let name, let parent):
            groupRow(name: name, parent: parent)
        case .namespace(let namespace, let parent):
            namespaceRow(namespace, parent: parent)
        case .emptyMessage(let text, _):
            emptyRow(text)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        HStack(spacing: 4) {
            indentAndChevron
            Text(text)
                .font(.callout)
                .italic()
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var indentAndChevron: some View {
        if row.depth > 0 {
            Spacer().frame(width: CGFloat(row.depth) * 14)
        }
        if row.isExpandable {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
        }
    }

    private func checkbox(
        _ state: SidebarRow.CheckState, action: @escaping () -> Void
    ) -> some View {
        let symbol = switch state {
        case .checked: "checkmark.square.fill"
        case .unchecked: "square"
        case .mixed: "minus.square.fill"
        }
        return Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(state == .unchecked ? .secondary : Color.accentColor)
        }
        .buttonStyle(.borderless)
    }

    private func groupRow(name: String, parent: DBCore.Namespace) -> some View {
        HStack(spacing: 4) {
            indentAndChevron
            if let state = row.checkState {
                checkbox(state) {
                    // Not all visible → make all visible; all visible → hide all.
                    session.setGroupVisible(state != .checked, group: name, in: parent)
                }
                .help("Show or hide all tables in \(name)")
            }
            Label(name, systemImage: "folder.fill")
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpand)
    }

    private func namespaceRow(
        _ namespace: DBCore.Namespace, parent: DBCore.Namespace?
    ) -> some View {
        let isTable = namespace.kind.isTable
        return HStack(spacing: 4) {
            indentAndChevron
            if let state = row.checkState {
                checkbox(state) { toggleCheckbox(namespace, state: state) }
                    .help(isTable
                        ? "Show or hide \(namespace.name)"
                        : "Show or hide \(namespace.name) and everything in it")
            }
            Label(namespace.name, systemImage: SidebarNode.icon(for: namespace))
                .foregroundStyle(row.isHidden ? .tertiary : .primary)
            if row.note != nil {
                Image(systemName: "note.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if row.isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(row.note ?? "")
        .contentShape(Rectangle())
        .modifier(TableTapModifier(
            isTable: isTable,
            action: {
                if session.editingVisibility {
                    session.setHidden(!row.isHidden, for: namespace)
                } else {
                    session.openTable(namespace)
                }
            }))
        .modifier(ExpandTapModifier(
            isExpandable: row.isExpandable,
            action: onToggleExpand))
        .contextMenu {
            // Child views: their bodies (and session reads) only run when
            // the menu is actually opened, keeping row updates cheap.
            if isTable {
                TableRowMenu(
                    namespace: namespace, parent: parent, session: session,
                    noteTarget: $noteTarget, groupTarget: $groupTarget,
                    dropTableRequest: $dropTableRequest)
            } else {
                ContainerRowMenu(
                    namespace: namespace, session: session,
                    createTableParent: $createTableParent)
            }
        }
    }

    /// Checkbox semantics: tables toggle; for a schema/database, hiding sets
    /// one flag on the namespace itself (cheap even with thousands of
    /// tables, and no children need to be loaded), unhiding restores the
    /// previous per-table state, and the mixed state ("visible, but
    /// something inside is hidden") unhides the whole subtree.
    private func toggleCheckbox(
        _ namespace: DBCore.Namespace, state: SidebarRow.CheckState
    ) {
        if namespace.kind.isTable {
            session.setHidden(state == .checked, for: namespace)
            return
        }
        switch state {
        case .unchecked:
            session.setHidden(false, for: namespace)
        case .mixed:
            session.unhideAll(in: namespace)
        case .checked:
            session.setHidden(true, for: namespace)
        }
    }
}

/// Context menu for a table row. Session state is read in this body, which
/// only runs when the menu opens.
private struct TableRowMenu: View {
    let namespace: DBCore.Namespace
    let parent: DBCore.Namespace?
    let session: ConnectionSession
    @Binding var noteTarget: DBCore.Namespace?
    @Binding var groupTarget: DBCore.Namespace?
    @Binding var dropTableRequest: SidebarView.DropTableRequest?

    var body: some View {
        Button("Open Table") { session.openTable(namespace) }
        Button("Show Structure") { session.openTable(namespace, mode: .structure) }
        Button("Query Table") {
            // Point the connection at the table's database first when the
            // generated SQL cannot name it (no-op for other drivers).
            Task {
                await session.switchToRootNamespaceIfNeeded(for: namespace)
                session.openQueryTab(
                    initialSQL: SidebarNode.defaultQuery(for: namespace, in: session),
                    runImmediately: true)
            }
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
                dropTableRequest = SidebarView.DropTableRequest(
                    table: namespace,
                    parent: parent,
                    sql: DDLStatementBuilder.dropTable(namespace, for: session.descriptor))
            }
        }
    }
}

/// Context menu for a schema/database row.
private struct ContainerRowMenu: View {
    let namespace: DBCore.Namespace
    let session: ConnectionSession
    @Binding var createTableParent: DBCore.Namespace?

    var body: some View {
        let kindLabel = namespace.kind == .database ? "Database" : "Schema"
        let isHidden = session.isHidden(namespace)
        Button("New Query") { session.openQueryTab() }
        Button(isHidden ? "Unhide \(kindLabel)" : "Hide \(kindLabel)") {
            session.setHidden(!isHidden, for: namespace)
        }
        Button("Show All Tables") { session.unhideAll(in: namespace) }
        if session.descriptor.supportsDDL {
            Divider()
            Button("New Table…") { createTableParent = namespace }
        }
    }
}

/// Sidebar node kinds and shared helpers.
enum SidebarNode {
    /// A real namespace or a user-defined table group.
    enum Kind: Equatable {
        case namespace(DBCore.Namespace, parent: DBCore.Namespace?)
        case group(String, parent: DBCore.Namespace)
        /// A non-interactive "nothing here" row under an expanded, empty parent.
        case emptyMessage(String, parent: DBCore.Namespace)
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

    @MainActor
    static func defaultQuery(
        for namespace: DBCore.Namespace, in session: ConnectionSession
    ) -> String {
        let descriptor = session.descriptor
        if descriptor.queryLanguage == .mongo {
            return "db.\(namespace.path.joined(separator: ".")).find({}).limit(100)"
        }
        let path = descriptor.sqlTablePath(namespace.path)
            .map { descriptor.quoted($0) }.joined(separator: ".")
        return "SELECT * FROM \(path) LIMIT 100;"
    }
}

/// One row of the flattened sidebar outline (see
/// `ConnectionSession.sidebarRows(expanded:)` for why the tree is flat).
///
/// Carries every value the row renders from, so the row view is a pure
/// function of this struct: rows whose data didn't change are skipped
/// entirely on updates (`SidebarOutlineRow` is `.equatable()`).
struct SidebarRow: Identifiable, Equatable {
    enum CheckState {
        case checked, unchecked, mixed
    }

    let kind: SidebarNode.Kind
    let depth: Int
    let isHidden: Bool
    let note: String?
    /// Visibility-edit mode (checkboxes shown).
    let editing: Bool
    /// Checkbox state while editing; nil outside edit mode.
    let checkState: CheckState?

    var id: String {
        switch kind {
        case .namespace(let namespace, _): return namespace.id
        case .group(let name, let parent): return parent.id + "#group:" + name
        case .emptyMessage(_, let parent): return parent.id + "#empty"
        }
    }

    var isExpandable: Bool {
        switch kind {
        case .group: return true
        case .namespace(let namespace, _): return namespace.isExpandable
        case .emptyMessage: return false
        }
    }
}

extension DBCore.Namespace.Kind {
    var isTable: Bool {
        if case .table = self { return true }
        return false
    }
}

/// Attaches a tap gesture only to expandable rows so they toggle open/closed;
/// table rows keep their own open-table gesture from `TableTapModifier`.
private struct ExpandTapModifier: ViewModifier {
    let isExpandable: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isExpandable {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

/// Attaches a tap gesture only for table rows, letting non-table (expandable)
/// namespace rows fall through to the row's tap-to-expand.
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

/// How a result set is rendered, switchable for every provider type.
enum ResultsViewMode: String, CaseIterable {
    case table = "Table"
    case tree = "Tree"
    case json = "JSON"

    static func isDocumentShaped(_ columns: [ColumnMeta]) -> Bool {
        columns.count == 1 && columns[0].dbTypeName == "document"
    }

    /// Shape-based default until the user picks explicitly: document-shaped
    /// results (Mongo) open in the tree, tabular results in the flat table.
    static func effective(
        _ selected: ResultsViewMode?, columns: [ColumnMeta]
    ) -> ResultsViewMode {
        selected ?? (isDocumentShaped(columns) ? .tree : .table)
    }
}

/// Table / Tree / JSON segmented toggle, shown in the results status row.
struct ResultsViewModePicker: View {
    @Binding var selection: ResultsViewMode?
    let columns: [ColumnMeta]

    var body: some View {
        Picker("View", selection: Binding(
            get: { ResultsViewMode.effective(selection, columns: columns) },
            set: { selection = $0 }
        )) {
            ForEach(ResultsViewMode.allCases, id: \.self) {
                Text($0.rawValue).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Switch between table, tree, and raw JSON view")
    }
}

/// Menu in the query status row that points unqualified SQL names at a
/// schema (Postgres `SET search_path`) or database (MySQL `USE`) for the
/// whole session. Only rendered when the driver advertises the capability.
struct ActiveNamespacePicker: View {
    @Bindable var session: ConnectionSession

    private var kind: DriverDescriptor.ActiveNamespaceKind? {
        session.descriptor.activeNamespaceKind
    }

    /// The connection default a reset returns to: MySQL falls back to the
    /// profile's database (there is no "un-USE"), Postgres to the default
    /// search path.
    private var defaultTitle: String {
        if kind == .database, let database = session.profile.database,
           !database.isEmpty {
            return "Default (\(database))"
        }
        return "Default"
    }

    var body: some View {
        Menu {
            Button {
                Task { await session.setActiveNamespace(nil) }
            } label: {
                if session.activeNamespace == nil {
                    Label(defaultTitle, systemImage: "checkmark")
                } else {
                    Text(defaultTitle)
                }
            }
            .disabled(kind == .database && !hasResetTarget)
            Divider()
            ForEach(session.switchableNamespaces, id: \.self) { name in
                Button {
                    Task { await session.setActiveNamespace(name) }
                } label: {
                    if session.activeNamespace == name {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                if session.activeNamespaceError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("\(kind?.displayName ?? ""): \(session.activeNamespace ?? "default")")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(helpText)
    }

    /// MySQL can only "reset" by re-USEing the profile's database; without
    /// one the Default item is disabled.
    private var hasResetTarget: Bool {
        !(session.profile.database ?? "").isEmpty
    }

    private var helpText: String {
        if let error = session.activeNamespaceError {
            return "Could not switch: \(error)"
        }
        let noun = kind?.displayName.lowercased() ?? "namespace"
        return "The \(noun) unqualified names in SQL queries resolve against "
            + "(applies to the whole connection)"
    }
}

/// Renders a result set in the given mode. Tabular rows are wrapped as one
/// document per row for the tree/JSON modes; the mode toggle itself lives in
/// the enclosing view's status row (`ResultsViewModePicker`).
struct ResultsArea: View {
    let columns: [ColumnMeta]
    let rows: [ResultRow]
    let version: Int
    let mode: ResultsViewMode
    var editing: ResultsTableView.EditingConfig?

    private var isDocumentShaped: Bool {
        ResultsViewMode.isDocumentShaped(columns)
    }

    var body: some View {
        switch mode {
        case .table:
            ResultsTableView(
                columns: columns, rows: rows, version: version, editing: editing)
        case .tree:
            DocumentResultsView(rows: documentRows, detailMode: .tree)
        case .json:
            DocumentResultsView(rows: documentRows, detailMode: .json)
        }
    }

    /// Document-shaped results pass through; tabular rows become one
    /// `{column: value}` document each so the tree/JSON renderers apply.
    private var documentRows: [ResultRow] {
        if isDocumentShaped { return rows }
        return rows.map { row in
            var doc: [String: DBValue] = [:]
            for (index, column) in columns.enumerated()
            where index < row.values.count {
                doc[column.name] = row.values[index]
            }
            return ResultRow(id: row.id, values: [.document(doc)])
        }
    }
}

// MARK: - Query view

struct QueryView: View {
    @Bindable var tab: QueryTab
    let session: ConnectionSession
    @State private var savingQuery = false
    @State private var savedQueryName = ""
    @State private var confirmingAnalyze = false
    /// nil until the user picks explicitly, so the shape-based default
    /// still applies when the tab switches between result shapes.
    @State private var viewMode: ResultsViewMode?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                SyntaxTextEditor(
                    text: $tab.queryText, language: tab.language,
                    completionProvider: session.completionProvider)
                    .frame(minHeight: 80)
                statusBar
            }
            if let plan = tab.explainPlan {
                ExplainPlanView(plan: plan, onClose: { tab.dismissExplain() })
                    .frame(minHeight: 120)
            } else {
                ResultsArea(
                    columns: tab.columns, rows: tab.rows, version: tab.resultVersion,
                    mode: ResultsViewMode.effective(viewMode, columns: tab.columns))
                    .frame(minHeight: 120)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Spacer()
                HistoryMenu(tab: tab, session: session)
                saveControl
                ExportMenu(tab: tab)
                if session.descriptor.explainSupport != .none {
                    explainControl
                }
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
        .alert("Run Query to Analyze?", isPresented: $confirmingAnalyze) {
            Button("Cancel", role: .cancel) {}
            Button("Run and Analyze") { tab.explain(analyze: true) }
        } message: {
            Text("""
                Explain Analyze executes the statement to measure it — \
                including any INSERT, UPDATE, or DELETE side effects.
                """)
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

    /// "Explain" toolbar control: a plain button for plan-only engines, a
    /// menu adding "Explain Analyze" where supported. Analyze on a writing
    /// statement asks for confirmation first (it really executes).
    @ViewBuilder
    private var explainControl: some View {
        let isEmpty = tab.queryText.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
        let isBusy = tab.explainState == .running
        if session.descriptor.explainSupport == .planAndAnalyze {
            Menu {
                Button("Explain") { tab.explain(analyze: false) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Explain Analyze (runs the query)") { requestExplainAnalyze() }
            } label: {
                Label("Explain", systemImage: "list.bullet.indent")
            }
            .menuIndicator(.visible)
            .disabled(isEmpty || isBusy)
            .help("Show the query's execution plan")
        } else {
            Button {
                tab.explain(analyze: false)
            } label: {
                Label("Explain", systemImage: "list.bullet.indent")
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(isEmpty || isBusy)
            .help("Show the query's execution plan")
        }
    }

    /// Mongo explain wraps read-only commands, so no confirmation needed;
    /// SQL statements that aren't plain reads get the alert.
    private func requestExplainAnalyze() {
        if tab.language == .sql,
           !ExplainStatementBuilder.isReadOnlyStatement(tab.queryText) {
            confirmingAnalyze = true
        } else {
            tab.explain(analyze: true)
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
            if tab.explainState == .running {
                ProgressView().controlSize(.small)
                Text("Explaining…")
            } else if case .failed(let message) = tab.explainState {
                Text("Explain failed: \(message)")
                    .foregroundStyle(.red).textSelection(.enabled)
            } else {
                runStatus
            }
            Spacer()
            ExportStatusView(tab: tab)
            if session.descriptor.activeNamespaceKind != nil {
                ActiveNamespacePicker(session: session)
            }
            ResultsViewModePicker(selection: $viewMode, columns: tab.columns)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder
    private var runStatus: some View {
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
