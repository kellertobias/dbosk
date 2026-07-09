import Connections
import DBCore
import DBDriverPostgres
import SwiftUI

extension ColorTag {
    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }

    var displayName: String { rawValue.capitalized }
}

struct ConnectionListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var editingProfile: ConnectionProfile?
    @State private var showingNewProfile = false

    /// Groups sorted by name; ungrouped connections come last.
    private var groupedProfiles: [(group: String?, profiles: [ConnectionProfile])] {
        let grouped = Dictionary(grouping: appModel.profiles) { $0.groupName }
        let named = grouped
            .filter { $0.key != nil }
            .sorted { ($0.key ?? "") < ($1.key ?? "") }
            .map { (group: $0.key, profiles: $0.value) }
        let ungrouped = grouped[nil].map { [(group: String?.none, profiles: $0)] } ?? []
        return named + ungrouped
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(groupedProfiles, id: \.group) { section in
                    Section(section.group ?? "Connections") {
                        ForEach(section.profiles) { profile in
                            row(for: profile)
                        }
                    }
                }
            }
            if let error = appModel.connectionError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding()
            }
            if appModel.isConnecting {
                ProgressView().padding()
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            Button {
                showingNewProfile = true
            } label: {
                Label("New Connection", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingNewProfile) {
            ConnectionEditView(profile: nil)
        }
        .sheet(item: $editingProfile) { profile in
            ConnectionEditView(profile: profile)
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func row(for profile: ConnectionProfile) -> some View {
        HStack {
            Circle()
                .fill(profile.colorTag?.color ?? Color.secondary.opacity(0.25))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(profile.name).font(.headline)
                Text(subtitle(for: profile))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") {
                Task { await appModel.connect(to: profile) }
            }
            .disabled(appModel.isConnecting)
        }
        .contextMenu {
            Button("Edit…") { editingProfile = profile }
            Button("Delete", role: .destructive) { appModel.delete(profile) }
        }
    }

    private func subtitle(for profile: ConnectionProfile) -> String {
        var parts = [profile.driverID]
        if let host = profile.host {
            parts.append("\(host)\(profile.port.map { ":\($0)" } ?? "")")
        }
        if let database = profile.database { parts.append(database) }
        return parts.joined(separator: " · ")
    }
}

struct ConnectionEditView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let profile: ConnectionProfile?

    @State private var driverID = PostgresDriver.descriptor.id
    @State private var name = ""
    @State private var groupName = ""
    @State private var colorTag: ColorTag?
    @State private var host = "localhost"
    @State private var port = ""
    @State private var user = ""
    @State private var database = ""
    @State private var tls: ResolvedConnectionConfig.TLSMode = .preferred
    @State private var credentialMode: CredentialMode = .password
    @State private var password = ""
    @State private var scriptPath = ""
    @State private var scriptArgs = ""

    enum CredentialMode: String, CaseIterable {
        case none = "None"
        case password = "Password"
        case script = "Script"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile == nil ? "New Connection" : "Edit Connection")
                .font(.title2)

            Form {
                Picker("Database", selection: $driverID) {
                    ForEach(AppModel.availableDrivers, id: \.id) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
                TextField("Name", text: $name)
                HStack {
                    TextField("Group", text: $groupName, prompt: Text("Optional"))
                    if !existingGroups.isEmpty {
                        Menu {
                            ForEach(existingGroups, id: \.self) { group in
                                Button(group) { groupName = group }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                    }
                }
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        colorSwatch(nil)
                        ForEach(ColorTag.allCases, id: \.self) { tag in
                            colorSwatch(tag)
                        }
                    }
                }
                TextField("Host", text: $host)
                TextField("Port", text: $port, prompt: Text(defaultPortPrompt))
                    .frame(maxWidth: 120)
                TextField("User", text: $user)
                TextField("Database", text: $database)
                Picker("TLS", selection: $tls) {
                    ForEach(ResolvedConnectionConfig.TLSMode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Credentials", selection: $credentialMode) {
                    ForEach(CredentialMode.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                switch credentialMode {
                case .none:
                    EmptyView()
                case .password:
                    SecureField("Password", text: $password)
                case .script:
                    TextField("Script path", text: $scriptPath)
                    TextField("Arguments", text: $scriptArgs)
                    Text("The script must print JSON with host, port, user, password, database, or uri.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { populate() }
    }

    private var existingGroups: [String] {
        Array(Set(appModel.profiles.compactMap(\.groupName))).sorted()
    }

    private func colorSwatch(_ tag: ColorTag?) -> some View {
        Button {
            colorTag = tag
        } label: {
            ZStack {
                Circle()
                    .fill(tag?.color ?? Color.secondary.opacity(0.25))
                    .frame(width: 16, height: 16)
                if tag == nil {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if colorTag == tag {
                    Circle().strokeBorder(Color.primary, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tag?.displayName ?? "None")
    }

    private var defaultPortPrompt: String {
        let port = AppModel.availableDrivers
            .first { $0.id == driverID }?.defaultPort
        return port.map(String.init) ?? ""
    }

    private func populate() {
        guard let profile else { return }
        driverID = profile.driverID
        name = profile.name
        groupName = profile.groupName ?? ""
        colorTag = profile.colorTag
        host = profile.host ?? ""
        port = profile.port.map(String.init) ?? ""
        user = profile.user ?? ""
        database = profile.database ?? ""
        tls = profile.tls
        switch profile.credentialSource {
        case .none:
            credentialMode = .none
        case .keychain:
            credentialMode = .password
            password = (try? appModel.keychain.password(for: profile.id)) ?? ""
        case .script(let config):
            credentialMode = .script
            scriptPath = config.path
            scriptArgs = config.args.joined(separator: " ")
        }
    }

    private func save() {
        let source: CredentialSource
        switch credentialMode {
        case .none: source = .none
        case .password: source = .keychain
        case .script:
            let args = scriptArgs.split(separator: " ").map(String.init)
            source = .script(ScriptConfig(path: scriptPath, args: args))
        }
        let updated = ConnectionProfile(
            id: profile?.id ?? UUID(),
            name: name,
            groupName: groupName.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : groupName.trimmingCharacters(in: .whitespaces),
            colorTag: colorTag,
            driverID: driverID,
            host: host.isEmpty ? nil : host,
            port: Int(port),
            user: user.isEmpty ? nil : user,
            database: database.isEmpty ? nil : database,
            tls: tls,
            credentialSource: source
        )
        appModel.upsert(updated, password: credentialMode == .password ? password : nil)
        dismiss()
    }
}
