import DBCore
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var appModel
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
                QueryView(tab: session.queryTab)
            }
        }
        .navigationTitle(session.profile.name)
        .navigationSubtitle(session.profile.groupName ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appModel.disconnect()
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
}

struct SidebarView: View {
    @Bindable var session: ConnectionSession

    var body: some View {
        List {
            if let error = session.sidebarError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            OutlineGroup(
                session.rootNamespaces.map { NamespaceNode(namespace: $0, session: session) },
                children: \.children
            ) { node in
                Label(node.namespace.name, systemImage: node.icon)
                    .onTapGesture(count: 2) {
                        if case .table = node.namespace.kind {
                            session.queryTab.queryText = node.defaultQuery
                            session.queryTab.run()
                        }
                    }
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
        let path = namespace.path.map { "\"\($0)\"" }.joined(separator: ".")
        return "SELECT * FROM \(path) LIMIT 100;"
    }
}

struct QueryView: View {
    @Bindable var tab: QueryTab

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                TextEditor(text: $tab.queryText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                statusBar
            }
            ResultsTableView(columns: tab.columns, rows: tab.rows, version: tab.resultVersion)
                .frame(minHeight: 120)
        }
        .toolbar {
            ToolbarItemGroup {
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
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
