import Connections
import DBCore
import Export
import DBDriverMongo
import DBDriverMySQL
import DBDriverPostgres
import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    /// Drivers with a working implementation; SQLite, Redis, DynamoDB follow.
    static let availableDrivers: [DriverDescriptor] = [
        PostgresDriver.descriptor,
        MySQLDriver.descriptor,
        MongoDriver.descriptor,
    ]

    var profiles: [ConnectionProfile] = []
    /// Live sessions keyed by profile id; each gets its own window.
    var sessions: [UUID: ConnectionSession] = [:]
    var connectionError: String?
    var isConnecting = false

    private let profileStore = ProfileStore()
    private let resolver = CredentialResolver()
    let keychain = KeychainStore()

    init() {
        profiles = (try? profileStore.load()) ?? []
    }

    func saveProfiles() {
        do {
            try profileStore.save(profiles)
        } catch {
            connectionError = "Could not save connections: \(error.localizedDescription)"
        }
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
        do {
            let config = try await resolver.resolve(profile)
            let driver = try makeDriver(profile: profile, config: config)
            try await driver.connect()
            sessions[profile.id] = ConnectionSession(profile: profile, driver: driver)
            return true
        } catch {
            connectionError = String(describing: error)
            return false
        }
    }

    func disconnect(profileID: UUID) {
        let session = sessions.removeValue(forKey: profileID)
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

    var selectedTab: WorkTab? {
        tabs.first { $0.id == selectedTabID }
    }

    init(profile: ConnectionProfile, driver: any DatabaseDriver) {
        self.profile = profile
        self.driver = driver
    }

    /// Opens (or re-focuses) a table tab. Clicking a table always lands in
    /// Table mode; a tab already showing that table is reused.
    func openTable(_ namespace: Namespace) {
        guard case .table = namespace.kind else { return }
        if let existing = tabs.first(where: {
            if case .table(let browser) = $0.content {
                return browser.table?.path == namespace.path
            }
            return false
        }) {
            selectedTabID = existing.id
            return
        }
        let browser = TableBrowser(driver: driver)
        let tab = WorkTab(title: namespace.name, content: .table(browser))
        tabs.append(tab)
        selectedTabID = tab.id
        browser.select(namespace)
    }

    /// Opens a new raw-query tab, optionally prefilled and executed.
    func openQueryTab(initialSQL: String = "", runImmediately: Bool = false) {
        let queryTab = QueryTab(driver: driver)
        queryTab.queryText = initialSQL
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
        } catch {
            sidebarError = String(describing: error)
        }
    }

    func loadChildren(of namespace: Namespace) async {
        guard children[namespace.id] == nil else { return }
        do {
            children[namespace.id] = try await driver.listNamespaces(parent: namespace)
        } catch {
            sidebarError = String(describing: error)
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

    var queryText: String = ""
    var runState: RunState = .idle
    var exportState: ExportState = .idle
    var columns: [ColumnMeta] = []
    var rows: [ResultRow] = []
    /// Incremented whenever rows/columns change, so AppKit views know to reload.
    var resultVersion = 0

    private let driver: any DatabaseDriver
    private var runTask: Task<Void, Never>?
    private var cancelHandler: (@Sendable () async -> Void)?

    var pageSize = 500
    let language: DriverDescriptor.QueryLanguage

    init(driver: any DatabaseDriver) {
        self.driver = driver
        self.language = type(of: driver).descriptor.queryLanguage
    }

    func run() {
        guard runState != .running, runState != .streaming else { return }
        let sql = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }

        runState = .running
        columns = []
        rows = []
        resultVersion += 1
        let started = Date()

        runTask = Task { [driver, pageSize] in
            do {
                let execution = try await driver.execute(.sql(sql), pageSize: pageSize)
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
            } catch let error as DBError where error.kind == .cancelled {
                self.runState = .cancelled
            } catch {
                self.runState = .failed(String(describing: error))
            }
            self.cancelHandler = nil
        }
    }

    func stop() {
        let handler = cancelHandler
        runTask?.cancel()
        Task { await handler?() }
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

extension DBError.Kind: Equatable {}

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
    var title: String
    let content: Content

    init(title: String, content: Content) {
        self.title = title
        self.content = content
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
    var table: Namespace?
    var availableColumns: [ColumnMeta] = []
    /// Selected column names; empty = all columns.
    var selectedColumns: Set<String> = []
    var whereClause = ""
    var offset = 0
    var limit = 100
    var columnsError: String?
    var isLoadingColumns = false

    /// Executes the built query; reuses the streaming runner.
    let resultTab: QueryTab

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
        guard let query = builtQuery else { return }
        resultTab.queryText = query
        resultTab.run()
    }

    func nextPage() {
        offset += limit
        load()
    }

    func previousPage() {
        offset = max(0, offset - limit)
        load()
    }
}
