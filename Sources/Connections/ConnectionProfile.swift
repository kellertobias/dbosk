import DBCore
import Foundation

public struct ScriptConfig: Codable, Sendable, Hashable {
    public var path: String
    public var args: [String]
    public var timeoutSeconds: Double

    public init(path: String, args: [String] = [], timeoutSeconds: Double = 30) {
        self.path = path
        self.args = args
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum CredentialSource: Codable, Sendable, Hashable {
    /// Password stored in the macOS Keychain under the profile's UUID.
    case keychain
    /// Credentials resolved at connect time by running a user script that
    /// prints JSON to stdout.
    case script(ScriptConfig)
    case none
}

/// Color label for a connection, e.g. red for production. Rendering is up to
/// the UI layer; the model only stores the semantic tag.
public enum ColorTag: String, Codable, Sendable, Hashable, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray
}

/// A saved connection. Never contains secrets — those live in the Keychain
/// or are resolved by the script at connect time.
public struct ConnectionProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Optional group for organizing the connection list (e.g. "Production").
    public var groupName: String?
    public var colorTag: ColorTag?
    /// Matches `DriverDescriptor.id`, e.g. "postgres", "mysql", "mongodb", "sqlite".
    public var driverID: String
    public var host: String?
    public var port: Int?
    public var user: String?
    public var database: String?
    public var filePath: String?
    public var tls: ResolvedConnectionConfig.TLSMode
    public var credentialSource: CredentialSource

    public init(
        id: UUID = UUID(),
        name: String,
        groupName: String? = nil,
        colorTag: ColorTag? = nil,
        driverID: String,
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        database: String? = nil,
        filePath: String? = nil,
        tls: ResolvedConnectionConfig.TLSMode = .preferred,
        credentialSource: CredentialSource = .none
    ) {
        self.id = id
        self.name = name
        self.groupName = groupName
        self.colorTag = colorTag
        self.driverID = driverID
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.filePath = filePath
        self.tls = tls
        self.credentialSource = credentialSource
    }
}

extension ResolvedConnectionConfig.TLSMode {
    public var displayName: String {
        switch self {
        case .disabled: return "Disabled"
        case .preferred: return "Preferred"
        case .required: return "Required"
        }
    }
}
