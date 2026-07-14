import Connections
import DBCore
import Export
import DBDriverDynamoDB
import DBDriverMetabase
import DBDriverMongo
import DBDriverMySQL
import DBDriverPostgres
import DBDriverRedis
import DBDriverSQLite
import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    static let availableDrivers: [DriverDescriptor] = [
        PostgresDriver.descriptor,
        MySQLDriver.descriptor,
        MongoDriver.descriptor,
        SQLiteDriver.descriptor,
        RedisDriver.descriptor,
        DynamoDBDriver.descriptor,
        MetabaseDriver.descriptor,
    ]

    var profiles: [ConnectionProfile] = []
    /// User-defined labels, managed in Preferences and referenced by profiles.
    var labels: [ConnectionLabel] = []
    /// Live sessions keyed by profile id; each gets its own window.
    var sessions: [UUID: ConnectionSession] = [:]
    var connectionError: String?
    var isConnecting = false
    /// Set when a connect failed because the Metabase session token was
    /// rejected; the connection list presents the SSO login sheet for it.
    var metabaseLoginRequest: ConnectionProfile?

    private let profileStore = ProfileStore()
    private let labelStore = LabelStore()
    private let resolver = CredentialResolver()
    let keychain = KeychainStore()

    init() {
        labels = (try? labelStore.load()) ?? []
        profiles = (try? profileStore.load()) ?? []
        migrateLegacyColorTags()
    }

    /// The label a profile carries, if any.
    func label(for profile: ConnectionProfile) -> ConnectionLabel? {
        guard let id = profile.labelID else { return nil }
        return labels.first { $0.id == id }
    }

    func saveProfiles() {
        do {
            try profileStore.save(profiles)
        } catch {
            connectionError = "Could not save connections: \(error.localizedDescription)"
        }
    }

    // MARK: - Labels

    func saveLabels() {
        do {
            try labelStore.save(labels)
        } catch {
            connectionError = "Could not save labels: \(error.localizedDescription)"
        }
    }

    func upsertLabel(_ label: ConnectionLabel) {
        if let index = labels.firstIndex(where: { $0.id == label.id }) {
            labels[index] = label
        } else {
            labels.append(label)
        }
        saveLabels()
    }

    func deleteLabel(_ label: ConnectionLabel) {
        labels.removeAll { $0.id == label.id }
        var changedProfiles = false
        for index in profiles.indices where profiles[index].labelID == label.id {
            profiles[index].labelID = nil
            changedProfiles = true
        }
        if changedProfiles { saveProfiles() }
        saveLabels()
    }

    /// Converts any pre-labels `colorTag` on loaded profiles into named labels,
    /// reusing an existing label of the same color, so upgrading users keep the
    /// stripe/badge colors they had.
    private func migrateLegacyColorTags() {
        var changedLabels = false
        var changedProfiles = false
        for index in profiles.indices {
            guard let legacy = profiles[index].legacyColorTag else { continue }
            let label: ConnectionLabel
            if let existing = labels.first(where: { $0.colorTag == legacy }) {
                label = existing
            } else {
                label = ConnectionLabel(name: legacy.displayName, colorTag: legacy)
                labels.append(label)
                changedLabels = true
            }
            profiles[index].labelID = label.id
            profiles[index].legacyColorTag = nil
            changedProfiles = true
        }
        if changedLabels { saveLabels() }
        if changedProfiles { saveProfiles() }
    }

    func upsert(_ profile: ConnectionProfile, password: String?) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if case .keychain = profile.credentialSource, let password, !password.isEmpty {
            try? keychain.setPassword(password, for: profile.id)
        }
        saveProfiles()
    }

    func delete(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        try? keychain.deletePassword(for: profile.id)
        saveProfiles()
    }

    /// Connects and registers a session; returns true so the caller can open
    /// the session window. Reuses an existing live session for the profile.
    func connect(to profile: ConnectionProfile) async -> Bool {
        if sessions[profile.id] != nil { return true }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        var tunnel: SSHTunnel?
        var credentialDiagnostics: String?
        do {
            var config = try await resolver.resolve(profile)
            credentialDiagnostics = config.credentialDiagnostics

            // Route through an SSH tunnel first when configured: forward a
            // local port to the (resolved) database host and rewrite the
            // config to point at it. HTTP-API drivers are excluded — their
            // "host" is a base URL, not a TCP endpoint the tunnel could
            // forward to.
            let descriptor = AppModel.availableDrivers
                .first { $0.id == profile.driverID }
            if let tunnelConfig = profile.sshTunnel, config.filePath == nil,
               descriptor?.supportsSSHTunnel != false {
                let targetPort = config.port ?? descriptor?.defaultPort ?? 0
                tunnel = try await SSHTunnel.start(
                    config: tunnelConfig,
                    targetHost: config.host ?? "localhost",
                    targetPort: targetPort)
                config.host = "127.0.0.1"
                config.port = tunnel?.localPort
                config.uri = nil  // a URI would bypass the tunnel
            }

            let driver = try makeDriver(profile: profile, config: config)
            try await driver.connect()
            let session = ConnectionSession(profile: profile, driver: driver)
            session.tunnel = tunnel
            sessions[profile.id] = session
            return true
        } catch {
            tunnel?.stop()
            // An expired/missing Metabase session gets a fresh SSO login
            // prompt instead of a raw error message.
            if let dbError = error as? DBError, dbError.kind == .authenticationExpired,
               profile.driverID == MetabaseDriver.descriptor.id,
               MetabaseURL.normalized(profile.host) != nil {
                metabaseLoginRequest = profile
                return false
            }
            var message = String(describing: error)
            if let credentialDiagnostics {
                message += "\n\(credentialDiagnostics)"
            }
            connectionError = message
            return false
        }
    }

    func disconnect(profileID: UUID) {
        let session = sessions.removeValue(forKey: profileID)
        session?.tunnel?.stop()
        Task { await session?.driver.disconnect() }
    }

    private func makeDriver(
        profile: ConnectionProfile, config: ResolvedConnectionConfig
    ) throws -> any DatabaseDriver {
        switch profile.driverID {
        case PostgresDriver.descriptor.id:
            return try PostgresDriver(config: config)
        case MySQLDriver.descriptor.id:
            return try MySQLDriver(config: config)
        case MongoDriver.descriptor.id:
            return try MongoDriver(config: config)
        case SQLiteDriver.descriptor.id:
            return try SQLiteDriver(config: config)
        case RedisDriver.descriptor.id:
            return try RedisDriver(config: config)
        case DynamoDBDriver.descriptor.id:
            return try DynamoDBDriver(config: config)
        case MetabaseDriver.descriptor.id:
            return try MetabaseDriver(config: config)
        default:
            throw DBError(
                kind: .unsupported,
                message: "Driver \(profile.driverID) is not implemented yet")
        }
    }
}

// MARK: - Session

@Observable
@MainActor
final class ConnectionSession: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let driver: any DatabaseDriver

    var descriptor: DriverDescriptor { type(of: driver).descriptor }

    var rootNamespaces: [Namespace] = []
    var children: [Namespace.ID: [Namespace]] = [:]
    var sidebarError: String?
    var tabs: [WorkTab] = []
    var selectedTabID: WorkTab.ID?

    /// Live SSH tunnel carrying this session's connection, if any.
    var tunnel: SSHTunnel?
    /// User metadata: saved queries, table notes, groups, hidden flags.
    var metadata: ConnectionMetadata
    /// Transient sidebar toggle to reveal hidden tables.
    var showHiddenTables = false {
        didSet { invalidateSidebarNodes() }
    }
    /// Sidebar visibility edit mode: shows checkboxes on tables/groups.
    var editingVisibility = false {
        didSet { invalidateSidebarNodes() }
    }
    private let metadataStore = MetadataStore()

    /// Memoized sidebar structure per parent node id. SwiftUI re-evaluates
    /// the outline on every render pass; with thousands of tables the
    /// filter/group work is far too hot to redo each time. Derived data
    /// only — invalidated wherever its observable inputs change.
    @ObservationIgnored private var sidebarNodeCache: [String: [SidebarNode.Kind]] = [:]
    /// Parents with a child-listing query in flight, so a render pass during
    /// a slow load can't fire duplicate queries.
    @ObservationIgnored private var childLoadsInFlight: Set<String> = []
    /// Cached column listings for the query editor's typeahead, keyed by
    /// table namespace id. Loads are deduplicated like child listings.
    @ObservationIgnored var columnCache: [String: [ColumnMeta]] = [:]
    @ObservationIgnored private var columnLoadsInFlight: Set<String> = []
    @ObservationIgnored private var _completionProvider: SchemaCompletionProvider?

    /// Feeds the query editor's typeahead; lazily created, session-shared.
    var completionProvider: SchemaCompletionProvider {
        if let provider = _completionProvider { return provider }
        let provider = SchemaCompletionProvider(session: self)
        _completionProvider = provider
        return provider
    }

    var selectedTab: WorkTab? {
        tabs.first { $0.id == selectedTabID }
    }

    init(profile: ConnectionProfile, driver: any DatabaseDriver) {
        self.profile = profile
        self.driver = driver
        self.metadata = MetadataStore().load(for: profile.id)
    }

    // MARK: User metadata

    private func persistMetadata() {
        try? metadataStore.save(metadata, for: profile.id)
    }

    func recordHistory(text: String, succeeded: Bool) {
        metadata.recordHistory(text: text, succeeded: succeeded)
        persistMetadata()
    }

    func clearHistory() {
        metadata.history = []
        persistMetadata()
    }

    @discardableResult
    func saveQuery(named name: String, text: String) -> SavedQuery {
        let query = SavedQuery(name: name, text: text)
        metadata.savedQueries.append(query)
        persistMetadata()
        return query
    }

    /// Overwrites the text of an existing saved query, returning the updated copy.
    @discardableResult
    func updateSavedQuery(_ query: SavedQuery, text: String) -> SavedQuery? {
        guard let index = metadata.savedQueries.firstIndex(where: { $0.id == query.id })
        else { return nil }
        metadata.savedQueries[index].text = text
        persistMetadata()
        return metadata.savedQueries[index]
    }

    func deleteSavedQuery(_ query: SavedQuery) {
        metadata.savedQueries.removeAll { $0.id == query.id }
        persistMetadata()
    }

    func renameSavedQuery(_ query: SavedQuery, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = metadata.savedQueries.firstIndex(where: { $0.id == query.id })
        else { return }
        metadata.savedQueries[index].name = trimmed
        persistMetadata()
    }

    // Lookups use the namespace's precomputed `pathKey` (same key
    // `ConnectionMetadata.key(for:)` produces) — these run per row per
    // render pass, so no per-call path joins.

    func note(for namespace: Namespace) -> String? {
        metadata.tables[namespace.pathKey]?.note
    }

    func setNote(_ note: String?, for namespace: Namespace) {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.update(namespace.path) {
            $0.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        persistMetadata()
    }

    func group(for namespace: Namespace) -> String? {
        metadata.tables[namespace.pathKey]?.group
    }

    func setGroup(_ group: String?, for namespace: Namespace) {
        metadata.update(namespace.path) { $0.group = group }
        invalidateSidebarNodes()
        persistMetadata()
    }

    func isHidden(_ namespace: Namespace) -> Bool {
        metadata.tables[namespace.pathKey]?.hidden ?? false
    }

    func setHidden(_ hidden: Bool, for namespace: Namespace) {
        metadata.update(namespace.path) { $0.hidden = hidden }
        invalidateSidebarNodes()
        persistMetadata()
    }

    /// Unhides `parent` itself and everything stored below it. Prefix-scans
    /// stored metadata entries, so cost is independent of table count.
    func unhideAll(in parent: Namespace) {
        metadata.update(parent.path) { $0.hidden = false }
        metadata.unhideDescendants(of: parent.path)
        invalidateSidebarNodes()
        persistMetadata()
    }

    /// True when any table or schema below `namespace` is hidden.
    func hasHiddenDescendants(_ namespace: Namespace) -> Bool {
        metadata.hasHiddenDescendants(of: namespace.path)
    }

    /// Tables of a parent, ignoring visibility (for the edit-mode checklist).
    func allTables(in parent: Namespace) -> [Namespace] {
        (children[parent.id] ?? []).filter(\.kind.isTable)
    }

    /// "All" clears every hidden flag (tables and schemas alike); "None"
    /// hides every loaded table.
    func setAllTablesVisible(_ visible: Bool) {
        if visible {
            metadata.unhideAll()
        } else {
            for siblings in children.values {
                for namespace in siblings where namespace.kind.isTable {
                    metadata.update(namespace.path) { $0.hidden = true }
                }
            }
        }
        invalidateSidebarNodes()
        persistMetadata()
    }

    /// Sets visibility for all tables of `parent` belonging to `group`
    /// (nil group = ungrouped tables).
    func setGroupVisible(_ visible: Bool, group: String?, in parent: Namespace) {
        for namespace in allTables(in: parent)
        where self.group(for: namespace) == group {
            metadata.update(namespace.path) { $0.hidden = !visible }
        }
        invalidateSidebarNodes()
        persistMetadata()
    }

    // MARK: Sidebar tree

    private func invalidateSidebarNodes() {
        sidebarNodeCache = [:]
    }

    /// Child nodes of an expandable namespace: nested schemas, then group
    /// folders, then ungrouped tables — filtered by the visibility state.
    /// Memoized; a missing child list triggers one (deduplicated) load.
    func sidebarChildren(of namespace: Namespace) -> [SidebarNode.Kind]? {
        guard namespace.isExpandable else { return nil }
        // Read the observable inputs unconditionally so SwiftUI re-renders
        // the outline when they change, even when serving from cache.
        let loaded = children[namespace.id]
        let showAll = editingVisibility || showHiddenTables
        let tableMeta = metadata.tables

        if let cached = sidebarNodeCache[namespace.id] { return cached }
        guard let loaded else {
            loadChildrenIfNeeded(namespace)
            return []
        }
        var nodes: [SidebarNode.Kind] = []
        var groups: Set<String> = []
        var ungrouped: [Namespace] = []
        for child in loaded {
            let meta = tableMeta[child.pathKey]
            guard showAll || meta?.hidden != true else { continue }
            if !child.kind.isTable {
                nodes.append(.namespace(child, parent: namespace))
            } else if let group = meta?.group {
                groups.insert(group)
            } else {
                ungrouped.append(child)
            }
        }
        nodes += groups.sorted().map { .group($0, parent: namespace) }
        nodes += ungrouped.map { .namespace($0, parent: namespace) }
        // An expanded parent that loaded no visible children gets a quiet
        // placeholder so the user sees "there is nothing here" rather than a
        // silently empty disclosure.
        if nodes.isEmpty {
            let message = descriptor.rootNamespacesDefaultHidden
                ? "No tables you have access to" : "No tables"
            nodes = [.emptyMessage(message, parent: namespace)]
        }
        sidebarNodeCache[namespace.id] = nodes
        return nodes
    }

    /// Visible tables of `parent` belonging to a group folder. Memoized
    /// under the group node's id.
    func sidebarGroupChildren(group name: String, in parent: Namespace) -> [SidebarNode.Kind] {
        let loaded = children[parent.id]
        let showAll = editingVisibility || showHiddenTables
        let tableMeta = metadata.tables

        let cacheKey = parent.id + "#group:" + name
        if let cached = sidebarNodeCache[cacheKey] { return cached }
        let nodes: [SidebarNode.Kind] = (loaded ?? [])
            .compactMap { child in
                guard child.kind.isTable else { return nil }
                let meta = tableMeta[child.pathKey]
                guard meta?.group == name, showAll || meta?.hidden != true
                else { return nil }
                return .namespace(child, parent: parent)
            }
        sidebarNodeCache[cacheKey] = nodes
        return nodes
    }

    /// Kicks off a child load unless one already completed or is running —
    /// render passes during a slow listing must not stack duplicate queries.
    /// `onLoaded` fires after a load this call started completes.
    func loadChildrenIfNeeded(
        _ namespace: Namespace, onLoaded: (@MainActor () -> Void)? = nil
    ) {
        guard children[namespace.id] == nil,
              !childLoadsInFlight.contains(namespace.id) else { return }
        childLoadsInFlight.insert(namespace.id)
        Task {
            await loadChildren(of: namespace)
            childLoadsInFlight.remove(namespace.id)
            onLoaded?()
        }
    }

    /// Fetches and caches a table's columns for typeahead unless already
    /// cached or loading. `onLoaded` fires after a successful fetch.
    func loadColumnsIfNeeded(
        of table: Namespace, onLoaded: @escaping @MainActor () -> Void
    ) {
        guard columnCache[table.id] == nil,
              !columnLoadsInFlight.contains(table.id) else { return }
        columnLoadsInFlight.insert(table.id)
        Task {
            defer { columnLoadsInFlight.remove(table.id) }
            guard let columns = try? await driver.listColumns(of: table) else { return }
            columnCache[table.id] = columns
            onLoaded()
        }
    }

    /// The visible outline flattened into one list. The sidebar renders this
    /// with a single flat ForEach: SwiftUI's hierarchical List (nested
    /// DisclosureGroups) re-diffs the whole tree through its outline
    /// coordinator on every update — seconds with thousands of tables —
    /// while a flat list diffs in milliseconds. Each row carries all its
    /// display data so unchanged rows skip re-rendering entirely.
    func sidebarRows(expanded: Set<String>) -> [SidebarRow] {
        let editing = editingVisibility
        var rows: [SidebarRow] = []

        func checkState(for namespace: Namespace) -> SidebarRow.CheckState {
            if isHidden(namespace) { return .unchecked }
            if !namespace.kind.isTable, hasHiddenDescendants(namespace) {
                return .mixed
            }
            return .checked
        }

        func groupCheckState(name: String, parent: Namespace) -> SidebarRow.CheckState {
            var total = 0
            var visible = 0
            for table in allTables(in: parent) where group(for: table) == name {
                total += 1
                if !isHidden(table) { visible += 1 }
            }
            return visible == total ? .checked : (visible == 0 ? .unchecked : .mixed)
        }

        func append(_ kind: SidebarNode.Kind, depth: Int) {
            let row: SidebarRow
            switch kind {
            case .namespace(let namespace, _):
                row = SidebarRow(
                    kind: kind, depth: depth,
                    isHidden: isHidden(namespace),
                    note: note(for: namespace),
                    editing: editing,
                    checkState: editing ? checkState(for: namespace) : nil)
            case .group(let name, let parent):
                row = SidebarRow(
                    kind: kind, depth: depth,
                    isHidden: false, note: nil,
                    editing: editing,
                    checkState: editing
                        ? groupCheckState(name: name, parent: parent) : nil)
            case .emptyMessage:
                row = SidebarRow(
                    kind: kind, depth: depth, isHidden: false, note: nil,
                    editing: editing, checkState: nil)
            }
            rows.append(row)
            guard row.isExpandable, expanded.contains(row.id) else { return }
            let childKinds: [SidebarNode.Kind]
            switch kind {
            case .namespace(let namespace, _):
                childKinds = sidebarChildren(of: namespace) ?? []
            case .group(let name, let parent):
                childKinds = sidebarGroupChildren(group: name, in: parent)
            case .emptyMessage:
                childKinds = []
            }
            for child in childKinds { append(child, depth: depth + 1) }
        }

        let showAll = editing || showHiddenTables
        for root in rootNamespaces where showAll || !isHidden(root) {
            append(.namespace(root, parent: nil), depth: 0)
        }
        return rows
    }

    /// Opens (or re-focuses) a table tab. Clicking a table always lands in
    /// Table mode; a tab already showing that table is reused.
    func openTable(
        _ namespace: Namespace, mode: TableBrowser.DisplayMode = .data
    ) {
        guard case .table = namespace.kind else { return }
        if let existing = tabs.first(where: {
            if case .table(let browser) = $0.content {
                return browser.table?.path == namespace.path
            }
            return false
        }) {
            selectedTabID = existing.id
            if case .table(let browser) = existing.content {
                browser.setDisplayMode(mode)
            }
            return
        }
        let browser = TableBrowser(driver: driver)
        browser.displayMode = mode
        browser.resultTab.onExecuted = { [weak self] text, succeeded in
            self?.recordHistory(text: text, succeeded: succeeded)
        }
        // When generated SQL cannot name the table's database, every data
        // query (initial load, pagination, refresh) must first point the
        // connection at it — the driver routes by active namespace.
        if descriptor.activeNamespaceKind != nil,
           !descriptor.supportsDatabaseQualifiedSQL {
            browser.prepareForQuery = { [weak self] table in
                await self?.switchToRootNamespaceIfNeeded(for: table)
            }
        }
        let tab = WorkTab(title: namespace.name, content: .table(browser))
        tabs.append(tab)
        selectedTabID = tab.id
        browser.select(namespace)
    }

    // MARK: Active namespace

    /// The schema/database unqualified SQL names currently resolve against,
    /// when the user switched it; nil means the connection default. Session
    /// (connection) scoped — all query tabs share the one connection.
    var activeNamespace: String?
    var activeNamespaceError: String?

    /// Root namespaces the picker can offer (schemas for Postgres, databases
    /// for MySQL — exactly what the sidebar root lists for those drivers).
    var switchableNamespaces: [String] {
        guard let kind = descriptor.activeNamespaceKind else { return [] }
        let expected: Namespace.Kind = kind == .schema ? .schema : .database
        return rootNamespaces.filter { $0.kind == expected }.map(\.name)
    }

    /// Runs SET search_path / USE on the shared connection; reverts nothing
    /// on failure (the connection state is unchanged when the statement
    /// errors) and surfaces the message next to the picker. Nil means "back
    /// to the connection default" — for MySQL that re-USEs the profile's
    /// database, since there is no reset statement.
    func setActiveNamespace(_ name: String?) async {
        activeNamespaceError = nil
        do {
            if name == nil, descriptor.activeNamespaceKind == .database {
                guard let database = profile.database, !database.isEmpty else {
                    return  // nothing to reset to; the picker disables this
                }
                try await driver.setActiveNamespace(database)
            } else {
                try await driver.setActiveNamespace(name)
            }
            activeNamespace = name
        } catch {
            activeNamespaceError = String(describing: error)
        }
    }

    /// Switches the session's active namespace to `namespace`'s root database
    /// when the driver routes SQL by active namespace instead of a database-
    /// qualified name (`supportsDatabaseQualifiedSQL == false`). No-op for
    /// every other driver, or when the root is already active — so callers
    /// may invoke it unconditionally before running table-scoped SQL.
    func switchToRootNamespaceIfNeeded(for namespace: Namespace) async {
        guard descriptor.activeNamespaceKind != nil,
              !descriptor.supportsDatabaseQualifiedSQL,
              let root = namespace.path.first,
              activeNamespace != root
        else { return }
        await setActiveNamespace(root)
    }

    /// Opens a new raw-query tab, optionally prefilled and executed.
    func openQueryTab(
        initialSQL: String = "",
        saved: SavedQuery? = nil,
        runImmediately: Bool = false
    ) {
        let queryTab = QueryTab(driver: driver)
        queryTab.queryText = saved?.text ?? initialSQL
        queryTab.savedQuery = saved
        queryTab.onExecuted = { [weak self] text, succeeded in
            self?.recordHistory(text: text, succeeded: succeeded)
        }
        let tab = WorkTab(title: "Query", content: .query(queryTab))
        tabs.append(tab)
        selectedTabID = tab.id
        if runImmediately { queryTab.run() }
    }

    func close(_ tab: WorkTab) {
        if case .query(let queryTab) = tab.content { queryTab.stop() }
        if case .table(let browser) = tab.content { browser.resultTab.stop() }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs[safe: min(index, tabs.count - 1)]?.id
        }
    }

    func loadRoot() async {
        do {
            rootNamespaces = try await driver.listNamespaces(parent: nil)
            applyDefaultRootVisibility()
        } catch {
            sidebarError = String(describing: error)
        }
    }

    /// Drivers that expose an org-wide set of databases (Metabase) list
    /// dozens of roots, so a fresh connection starts with all of them hidden
    /// and the sidebar offers "Choose Databases…" instead. Applies exactly
    /// once per connection — a persisted marker remembers it, so an explicit
    /// user choice (including "show everything", which prunes the stored
    /// entries) is never overridden on reconnect.
    private func applyDefaultRootVisibility() {
        guard descriptor.rootNamespacesDefaultHidden,
              !metadata.initialRootVisibilityApplied else { return }
        let roots = rootNamespaces.filter { $0.kind == .database }
        guard !roots.isEmpty else { return }
        metadata.initialRootVisibilityApplied = true
        // Pre-marker metadata that already has a root entry means the user
        // made a choice on an earlier version: only record the marker.
        if roots.allSatisfy({ metadata.tables[$0.pathKey] == nil }) {
            for root in roots {
                metadata.update(root.path) { $0.hidden = true }
            }
            invalidateSidebarNodes()
        }
        persistMetadata()
    }

    func loadChildren(of namespace: Namespace) async {
        guard children[namespace.id] == nil else { return }
        do {
            children[namespace.id] = try await driver.listNamespaces(parent: namespace)
            invalidateSidebarNodes()
        } catch {
            sidebarError = String(describing: error)
        }
    }

    /// Re-lists a parent's children, e.g. after CREATE/DROP TABLE.
    func reloadChildren(of namespace: Namespace) async {
        children[namespace.id] = nil
        invalidateSidebarNodes()
        await loadChildren(of: namespace)
    }

    func runDDL(_ statement: String) async throws {
        _ = try await driver.executeBatch([statement])
    }

    /// Closes any table tab showing `namespace` (after a drop).
    func closeTabs(showing namespace: Namespace) {
        for tab in tabs {
            if case .table(let browser) = tab.content,
               browser.table?.path == namespace.path {
                close(tab)
            }
        }
    }
}

// MARK: - Query tab

@Observable
@MainActor
final class QueryTab {
    enum RunState: Equatable {
        case idle
        case running
        case streaming
        case done(rowCount: Int, elapsed: TimeInterval)
        case failed(String)
        case cancelled
    }

    enum ExportState: Equatable {
        case idle
        case exporting(rows: Int)
        case done(URL)
        case failed(String)
    }

    enum ExplainState: Equatable {
        case idle
        case running
        case failed(String)
    }

    var queryText: String = ""
    /// The saved query this tab originated from / is linked to, if any.
    /// Its `text` is the last-saved snapshot used to detect unsaved edits.
    var savedQuery: SavedQuery?
    var runState: RunState = .idle
    var exportState: ExportState = .idle
    var explainState: ExplainState = .idle
    /// Non-nil while the plan panel replaces the results area; the last
    /// result set stays untouched underneath and reappears on dismiss.
    var explainPlan: ExplainPlan?
    var columns: [ColumnMeta] = []
    var rows: [ResultRow] = []
    /// Incremented whenever rows/columns change, so AppKit views know to reload.
    var resultVersion = 0

    private let driver: any DatabaseDriver
    private var runTask: Task<Void, Never>?
    private var explainTask: Task<Void, Never>?
    private var cancelHandler: (@Sendable () async -> Void)?

    var pageSize: Int
    let language: DriverDescriptor.QueryLanguage

    /// UserDefaults key for the streaming chunk size, set in Preferences.
    static let pageSizeDefaultsKey = "queryPageSize"

    init(driver: any DatabaseDriver) {
        self.driver = driver
        self.language = type(of: driver).descriptor.queryLanguage
        let stored = UserDefaults.standard.integer(forKey: Self.pageSizeDefaultsKey)
        self.pageSize = stored > 0 ? stored : 500
    }

    /// Invoked after each execution finishes (query text, success) — the
    /// session hooks this to record history.
    var onExecuted: ((String, Bool) -> Void)?

    /// When set, `run()` executes this structured query instead of `queryText`.
    /// Table mode uses it for drivers that generate their own browse SQL.
    var browseRequest: DriverQuery?

    /// True when linked to a saved query whose text differs from the editor.
    var hasUnsavedChanges: Bool {
        guard let savedQuery else { return false }
        return savedQuery.text != queryText
    }

    func run() {
        guard runState != .running, runState != .streaming else { return }
        let sql = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A browse request (set by Table mode for drivers that build their own
        // browse SQL) runs instead of the editor text; `queryText` stays as the
        // human-readable preview shown in history.
        let query: DriverQuery
        if let browseRequest {
            query = browseRequest
        } else {
            guard !sql.isEmpty else { return }
            query = .sql(sql)
        }

        runState = .running
        dismissExplain()
        columns = []
        rows = []
        resultVersion += 1
        let started = Date()

        runTask = Task { [driver, pageSize] in
            do {
                let execution = try await driver.execute(query, pageSize: pageSize)
                self.cancelHandler = execution.cancel
                self.columns = execution.columns
                self.runState = .streaming
                self.resultVersion += 1
                for try await chunk in execution.chunks {
                    self.rows.append(contentsOf: chunk.rows)
                    self.resultVersion += 1
                }
                self.runState = .done(
                    rowCount: self.rows.count,
                    elapsed: Date().timeIntervalSince(started))
                self.onExecuted?(sql, true)
            } catch let error as DBError where error.kind == .cancelled {
                self.runState = .cancelled
                self.onExecuted?(sql, false)
            } catch {
                self.runState = .failed(String(describing: error))
                self.onExecuted?(sql, false)
            }
            self.cancelHandler = nil
        }
    }

    func stop() {
        let handler = cancelHandler
        runTask?.cancel()
        Task { await handler?() }
    }

    /// Asks the engine for the query's execution plan. Unlike `run()`, the
    /// current result set is kept — the plan panel overlays it until
    /// dismissed. `analyze` executes the query for real counts and timings.
    func explain(analyze: Bool) {
        guard explainState != .running else { return }
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        explainState = .running
        explainTask = Task { [driver] in
            do {
                let plan = try await driver.explain(.sql(text), analyze: analyze)
                self.explainPlan = plan
                self.explainState = .idle
                self.onExecuted?(self.explainHistoryText(for: text, analyze: analyze), true)
            } catch is CancellationError {
                self.explainState = .idle
            } catch {
                self.explainState = .failed(String(describing: error))
            }
        }
    }

    func dismissExplain() {
        explainTask?.cancel()
        explainPlan = nil
        explainState = .idle
    }

    /// History records the statement that actually ran: the wrapped EXPLAIN
    /// for SQL engines, the user's text for Mongo (explain is a command
    /// wrapper there, not a query rewrite).
    private func explainHistoryText(for text: String, analyze: Bool) -> String {
        guard let dialect = type(of: driver).descriptor.sqlDialect else { return text }
        return ExplainStatementBuilder.statement(
            for: text, dialect: dialect, analyze: analyze)
    }

    /// Re-executes the current query and streams the full result to a file,
    /// so exports are not limited to the rows loaded in the UI.
    func export(format: ExportFormat, to url: URL) {
        let query = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if case .exporting = exportState { return }
        exportState = .exporting(rows: 0)
        Task { [driver, pageSize] in
            do {
                let execution = try await driver.execute(.sql(query), pageSize: pageSize)
                try await ResultExporter().export(
                    execution, format: format, to: url
                ) { progress in
                    Task { @MainActor in
                        self.exportState = .exporting(rows: progress.rowsWritten)
                    }
                }
                self.exportState = .done(url)
            } catch {
                self.exportState = .failed(String(describing: error))
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Work tabs

/// One open tab in a session: either a raw-query editor or a table browser.
@Observable
@MainActor
final class WorkTab: Identifiable {
    enum Content {
        case query(QueryTab)
        case table(TableBrowser)
    }

    let id = UUID()
    /// Fallback title for tabs not linked to a saved query.
    var baseTitle: String
    let content: Content

    init(title: String, content: Content) {
        self.baseTitle = title
        self.content = content
    }

    /// A query tab linked to a saved query shows its name, with a "(changed)"
    /// suffix while the editor holds unsaved edits.
    var title: String {
        if case .query(let queryTab) = content, let saved = queryTab.savedQuery {
            return saved.name + (queryTab.hasUnsavedChanges ? " (changed)" : "")
        }
        return baseTitle
    }

    var systemImage: String {
        switch content {
        case .query: return "terminal"
        case .table: return "tablecells"
        }
    }
}

// MARK: - Table browser (Full Table mode)

@Observable
@MainActor
final class TableBrowser {
    enum DisplayMode: String, CaseIterable {
        case data = "Data"
        case structure = "Structure"
    }

    var table: Namespace?
    var displayMode: DisplayMode = .data
    var availableColumns: [ColumnMeta] = []
    /// Selected column names; empty = all columns.
    var selectedColumns: Set<String> = []
    var whereClause = ""
    var offset = 0
    var limit = 100
    var columnsError: String?
    var isLoadingColumns = false

    /// Structure-mode state, loaded lazily on first switch to `.structure`.
    var structure: TableStructure?
    var structureError: String?
    var isLoadingStructure = false

    enum ApplyState: Equatable {
        case idle
        case applying
        case failed(String)
    }

    /// Staged edits awaiting Apply; overlays `resultTab.rows`, never mutates them.
    let pending = PendingChangeSet()
    var applyState: ApplyState = .idle
    /// Navigation blocked by pending edits; the UI confirms or cancels it.
    var pendingNavigation: (() -> Void)?
    /// Grid selection (display row indexes), for the toolbar delete button.
    var selectedDisplayRows = IndexSet()

    /// Executes the built query; reuses the streaming runner.
    let resultTab: QueryTab

    /// Awaited before each generated data query runs, so the session can
    /// point the connection at the table's database first (drivers whose
    /// generated SQL cannot name it — `supportsDatabaseQualifiedSQL` false).
    var prepareForQuery: (@MainActor (Namespace) async -> Void)?

    private let driver: any DatabaseDriver
    let descriptor: DriverDescriptor

    init(driver: any DatabaseDriver) {
        self.driver = driver
        self.descriptor = type(of: driver).descriptor
        self.resultTab = QueryTab(driver: driver)
    }

    func select(_ namespace: Namespace) {
        guard namespace != table else { return }
        table = namespace
        availableColumns = []
        selectedColumns = []
        whereClause = ""
        offset = 0
        columnsError = nil
        structure = nil
        structureError = nil
        discardChanges()
        pendingNavigation = nil
        // Editing needs the primary key upfront, so fetch the structure
        // eagerly instead of waiting for the first switch to Structure mode.
        if displayMode == .structure || descriptor.supportsTableEditing { loadStructure() }
        isLoadingColumns = true
        // Kick off the first page immediately; columns load in parallel so the
        // user sees data as fast as the server can deliver it.
        load()
        Task {
            do {
                availableColumns = try await driver.listColumns(of: namespace)
            } catch {
                columnsError = String(describing: error)
            }
            isLoadingColumns = false
        }
    }

    func toggleColumn(_ name: String) {
        if selectedColumns.contains(name) {
            selectedColumns.remove(name)
        } else {
            selectedColumns.insert(name)
        }
    }

    var builtQuery: String? {
        guard let table else { return nil }
        // Preserve table column order rather than selection order.
        let columns = selectedColumns.isEmpty
            ? []
            : availableColumns.map(\.name).filter { selectedColumns.contains($0) }
        return TableQueryBuilder.build(
            TableQueryBuilder.Request(
                table: table,
                columns: columns,
                filter: whereClause,
                offset: offset,
                limit: limit),
            for: descriptor)
    }

    func load() {
        guard let table, let query = builtQuery else { return }
        resultTab.queryText = query
        // When the driver builds its own browse SQL (heterogeneous engines
        // behind one connection), hand it the structured request; the query
        // string above is only the preview shown in history.
        if descriptor.buildsTableBrowseInDriver {
            let columns = selectedColumns.isEmpty
                ? []
                : availableColumns.map(\.name).filter { selectedColumns.contains($0) }
            let filter = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
            resultTab.browseRequest = .tableBrowse(TableBrowseRequest(
                path: table.path, columns: columns,
                filter: filter.isEmpty ? nil : filter,
                limit: limit, offset: offset))
        } else {
            resultTab.browseRequest = nil
        }
        if let prepareForQuery {
            Task {
                await prepareForQuery(table)
                resultTab.run()
            }
        } else {
            resultTab.run()
        }
    }

    /// Switches display mode, fetching the structure on first use.
    func setDisplayMode(_ mode: DisplayMode) {
        displayMode = mode
        if mode == .structure { loadStructure() }
    }

    func loadStructure(reload: Bool = false) {
        guard let table else { return }
        guard reload || (structure == nil && !isLoadingStructure) else { return }
        structureError = nil
        isLoadingStructure = true
        Task { [driver] in
            do {
                structure = try await driver.describeTable(table)
            } catch {
                structureError = String(describing: error)
            }
            isLoadingStructure = false
        }
    }

    func nextPage() {
        requestNavigation {
            self.offset += self.limit
            self.load()
        }
    }

    func previousPage() {
        requestNavigation {
            self.offset = max(0, self.offset - self.limit)
            self.load()
        }
    }

    // MARK: - Staged editing

    /// Nil when staged editing is allowed; otherwise a user-facing reason.
    var editingDisabledReason: String? {
        guard descriptor.supportsTableEditing else {
            return "\(descriptor.displayName) does not support editing"
        }
        guard let table else { return "No table selected" }
        guard table.kind == .table(.table) else { return "Only tables can be edited" }
        guard let structure else {
            return isLoadingStructure ? "Loading table structure…" : "Table structure unavailable"
        }
        let keyNames = structure.columns.filter(\.isPrimaryKey).map(\.name)
        guard !keyNames.isEmpty else { return "Table has no primary key" }
        guard case .done = resultTab.runState else { return "Waiting for table data…" }
        let loadedNames = Set(resultTab.columns.map(\.name))
        guard keyNames.allSatisfy(loadedNames.contains) else {
            return "Include the primary key column(s) to edit"
        }
        return nil
    }

    var isEditable: Bool { editingDisabledReason == nil }

    /// Runs `action` immediately, or parks it behind a discard confirmation
    /// when edits are pending.
    func requestNavigation(_ action: @escaping () -> Void) {
        if pending.isEmpty {
            action()
        } else {
            pendingNavigation = action
        }
    }

    func confirmPendingNavigation() {
        let action = pendingNavigation
        pendingNavigation = nil
        discardChanges()
        action?()
    }

    func cancelPendingNavigation() {
        pendingNavigation = nil
    }

    func discardChanges() {
        pending.discardAll()
        applyState = .idle
    }

    /// Generates the SQL for all pending changes: DELETEs first (freeing
    /// unique keys inserts may reuse), then UPDATEs, then INSERTs.
    func buildApplyStatements() throws -> [String] {
        guard let table, let structure else {
            throw DBError(kind: .queryFailed, message: "Table structure not loaded")
        }
        let columns = resultTab.columns
        let declaredTypes = Dictionary(
            structure.columns.map { ($0.name, $0.dbTypeName) },
            uniquingKeysWith: { first, _ in first })
        let keyColumns = structure.columns.filter(\.isPrimaryKey)

        // Result columns report "any" for SQLite, so prefer declared types.
        func columnType(at index: Int) -> String {
            declaredTypes[columns[index].name] ?? columns[index].dbTypeName
        }

        func parse(_ text: String?, columnName: String, typeName: String) throws -> DBValue {
            do {
                return try DBValueParser.parse(text, dbTypeName: typeName)
            } catch {
                throw DBError(
                    kind: .queryFailed,
                    message: "Column \"\(columnName)\": \(String(describing: error))")
            }
        }

        /// Original (pre-edit) primary-key values identifying `row`.
        func keyValues(for row: ResultRow) throws -> [MutationStatementBuilder.ColumnValue] {
            try keyColumns.map { key in
                guard let index = columns.firstIndex(where: { $0.name == key.name }),
                      let value = row.values[safe: index]
                else {
                    throw DBError(
                        kind: .queryFailed,
                        message: "Primary key column \"\(key.name)\" is not loaded")
                }
                return .init(column: key.name, value: value)
            }
        }

        var statements: [String] = []
        for rowID in pending.deletedRowIDs.sorted() {
            guard let row = resultTab.rows[safe: rowID] else { continue }
            statements.append(try MutationStatementBuilder.delete(
                from: table, matching: try keyValues(for: row), for: descriptor))
        }
        for (rowID, edits) in pending.cellEdits.sorted(by: { $0.key < $1.key })
        where !pending.deletedRowIDs.contains(rowID) {
            guard let row = resultTab.rows[safe: rowID] else { continue }
            let assignments = try edits.sorted { $0.key < $1.key }
                .map { columnIndex, text in
                    let name = columns[columnIndex].name
                    return MutationStatementBuilder.ColumnValue(
                        column: name,
                        value: try parse(text, columnName: name, typeName: columnType(at: columnIndex)))
                }
            statements.append(try MutationStatementBuilder.update(
                table, set: assignments, matching: try keyValues(for: row), for: descriptor))
        }
        for inserted in pending.insertedRows {
            let cells = inserted.cells.sorted { $0.key < $1.key }
            guard !cells.isEmpty else {
                throw DBError(kind: .queryFailed, message: "New row has no values")
            }
            let names = cells.map { columns[$0.key].name }
            let values = try cells.map { columnIndex, text in
                try parse(text, columnName: columns[columnIndex].name,
                          typeName: columnType(at: columnIndex))
            }
            statements.append(try MutationStatementBuilder.insert(
                into: table, columns: names, values: values, for: descriptor))
        }
        return statements
    }

    func runDDL(_ statement: String) async throws {
        _ = try await driver.executeBatch([statement])
    }

    /// Refresh after column-level DDL: projection and staged edits reference
    /// column indexes that may have shifted, so both reset.
    func refreshAfterSchemaChange() {
        discardChanges()
        selectedColumns = []
        loadStructure(reload: true)
        guard let table else { return }
        isLoadingColumns = true
        Task { [driver] in
            do {
                availableColumns = try await driver.listColumns(of: table)
            } catch {
                columnsError = String(describing: error)
            }
            isLoadingColumns = false
        }
        if displayMode == .data { load() }
    }

    /// Executes previewed statements atomically; on success clears the staged
    /// set and reloads the page. On failure the staged set stays intact (the
    /// transaction rolled back) so the user can fix and retry.
    func apply(statements: [String]) {
        guard !statements.isEmpty, applyState != .applying else { return }
        applyState = .applying
        Task { [driver] in
            do {
                _ = try await driver.executeBatch(statements)
                self.pending.discardAll()
                self.applyState = .idle
                self.load()
            } catch {
                self.applyState = .failed(String(describing: error))
            }
        }
    }
}
