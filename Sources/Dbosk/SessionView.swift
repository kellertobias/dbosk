import AppKit
import DBCore
import Export
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: ConnectionSession

    var body: some View {
        VStack(spacing: 0) {
            // Always-visible environment stripe (e.g. red = production).
            if let tag = session.profile.colorTag {
                Rectangle()
                    .fill(tag.color)
                    .frame(height: 3)
            }
            NavigationSplitView {
                SidebarView(session: session)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240)
            } detail: {
                VStack(spacing: 0) {
                    TabBarView(session: session)
                    Divider()
                    tabContent
                }
            }
        }
        .navigationTitle(session.profile.name)
        .navigationSubtitle(session.profile.groupName ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appModel.disconnect(profileID: session.profile.id)
                    dismiss()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
            if let tag = session.profile.colorTag {
                ToolbarItem(placement: .status) {
                    Label {
                        Text(session.profile.groupName ?? session.profile.name)
                    } icon: {
                        Circle().fill(tag.color).frame(width: 10, height: 10)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
        .task { await session.loadRoot() }
    }

    @ViewBuilder
    private var tabContent: some View {
        if let tab = session.selectedTab {
            switch tab.content {
            case .query(let queryTab):
                QueryView(tab: queryTab)
            case .table(let browser):
                TableModeView(browser: browser)
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
                Image(systemName: "plus")
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
    @Bindable var session: ConnectionSession
    @State private var hoveredNodeID: DBCore.Namespace.ID?

    var body: some View {
        List {
            if let error = session.sidebarError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            OutlineGroup(
                session.rootNamespaces.map { NamespaceNode(namespace: $0, session: session) },
                children: \.children
            ) { node in
                row(for: node)
            }
        }
    }

    private func row(for node: NamespaceNode) -> some View {
        HStack {
            Label(node.namespace.name, systemImage: node.icon)
            Spacer()
            // Raw-query shortcut on database/schema nodes.
            if node.namespace.isExpandable, hoveredNodeID == node.id {
                Button {
                    session.openQueryTab()
                } label: {
                    Text("SQL")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.2)))
                }
                .buttonStyle(.borderless)
                .help("New query on \(node.namespace.name)")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredNodeID = hovering ? node.id : nil
        }
        .onTapGesture {
            if case .table = node.namespace.kind {
                session.openTable(node.namespace)
            }
        }
        .contextMenu {
            if case .table = node.namespace.kind {
                Button("Open Table") { session.openTable(node.namespace) }
                Button("Query Table") {
                    session.openQueryTab(
                        initialSQL: node.defaultQuery, runImmediately: true)
                }
            } else {
                Button("New Query") { session.openQueryTab() }
            }
        }
    }
}

/// Adapter making lazy namespace loading work with OutlineGroup.
@MainActor
struct NamespaceNode: @MainActor Identifiable {
    let namespace: DBCore.Namespace
    let session: ConnectionSession

    var id: DBCore.Namespace.ID { namespace.id }

    var children: [NamespaceNode]? {
        guard namespace.isExpandable else { return nil }
        if let loaded = session.children[namespace.id] {
            return loaded.map { NamespaceNode(namespace: $0, session: session) }
        }
        // Trigger lazy load; OutlineGroup re-renders when children update.
        Task { await session.loadChildren(of: namespace) }
        return []
    }

    var icon: String {
        switch namespace.kind {
        case .database: return "cylinder"
        case .schema: return "folder"
        case .table(.view): return "eye"
        case .table(.collection): return "doc.text"
        case .table: return "tablecells"
        }
    }

    var defaultQuery: String {
        let descriptor = session.descriptor
        if descriptor.queryLanguage == .mongo {
            return "db.\(namespace.path.joined(separator: ".")).find({}).limit(100)"
        }
        let path = namespace.path.map { descriptor.quoted($0) }.joined(separator: ".")
        return "SELECT * FROM \(path) LIMIT 100;"
    }
}

/// Picks the right renderer: document-shaped results (Mongo) get the
/// two-column list + tree view, everything else the flat table.
struct ResultsArea: View {
    let columns: [ColumnMeta]
    let rows: [ResultRow]
    let version: Int

    var body: some View {
        if columns.count == 1, columns[0].dbTypeName == "document" {
            DocumentResultsView(rows: rows)
        } else {
            ResultsTableView(columns: columns, rows: rows, version: version)
        }
    }
}

// MARK: - Query view

struct QueryView: View {
    @Bindable var tab: QueryTab

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
            ToolbarItemGroup {
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
