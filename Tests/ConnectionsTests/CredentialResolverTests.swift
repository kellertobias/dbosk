import DBCore
import Foundation
import Testing

@testable import Connections

@Suite struct CredentialResolverTests {
    private func makeScript(_ json: String) throws -> ScriptConfig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cred.sh")
        try "#!/bin/sh\necho '\(json)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return ScriptConfig(path: url.path)
    }

    @Test func scriptValuesOverrideProfileFields() async throws {
        let script = try makeScript(
            #"{"host": "db.internal", "password": "s3cret", "port": 6543}"#)
        let profile = ConnectionProfile(
            name: "test", driverID: "postgres",
            host: "localhost", port: 5432, user: "app", database: "mydb",
            credentialSource: .script(script))

        let config = try await CredentialResolver().resolve(profile)
        #expect(config.host == "db.internal")     // overridden
        #expect(config.port == 6543)              // overridden
        #expect(config.user == "app")             // kept from profile
        #expect(config.database == "mydb")        // kept from profile
        #expect(config.password == "s3cret")
        #expect(config.uri == nil)
    }

    @Test func scriptURIWins() async throws {
        let script = try makeScript(
            #"{"uri": "postgres://u:p@example.com:5433/other"}"#)
        let profile = ConnectionProfile(
            name: "test", driverID: "postgres", host: "localhost",
            credentialSource: .script(script))

        let config = try await CredentialResolver().resolve(profile)
        #expect(config.uri == "postgres://u:p@example.com:5433/other")
    }

    @Test func keychainSourceLoadsPassword() async throws {
        let keychain = KeychainStore()
        let profile = ConnectionProfile(
            name: "kc", driverID: "postgres", host: "h", user: "u",
            credentialSource: .keychain)
        defer { try? keychain.deletePassword(for: profile.id) }
        try keychain.setPassword("from-keychain", for: profile.id)

        let config = try await CredentialResolver().resolve(profile)
        #expect(config.password == "from-keychain")
        #expect(config.host == "h")
    }

    @Test func noneSourceLeavesPasswordEmpty() async throws {
        let profile = ConnectionProfile(
            name: "test", driverID: "postgres", host: "h", user: "u")
        let config = try await CredentialResolver().resolve(profile)
        #expect(config.password == nil)
        #expect(config.host == "h")
    }
}

@Suite struct ProfileStoreTests {
    @Test func roundtripsProfiles() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-store-\(UUID().uuidString)/connections.json")
        let store = ProfileStore(fileURL: file)

        #expect(try store.load().isEmpty)

        let profiles = [
            ConnectionProfile(
                name: "prod", groupName: "Production", labelID: UUID(),
                driverID: "postgres", host: "prod.db", port: 5432,
                credentialSource: .keychain),
            ConnectionProfile(
                name: "local mongo", driverID: "mongodb", host: "localhost",
                credentialSource: .script(ScriptConfig(path: "/bin/echo", args: ["{}"]))),
        ]
        try store.save(profiles)
        let loaded = try store.load()
        #expect(loaded == profiles)
    }
}

@Suite struct KeychainStoreTests {
    @Test func roundtripAndDelete() throws {
        let keychain = KeychainStore()
        let id = UUID()
        defer { try? keychain.deletePassword(for: id) }

        #expect(try keychain.password(for: id) == nil)
        try keychain.setPassword("first", for: id)
        #expect(try keychain.password(for: id) == "first")
        try keychain.setPassword("second", for: id)  // update path
        #expect(try keychain.password(for: id) == "second")
        try keychain.deletePassword(for: id)
        #expect(try keychain.password(for: id) == nil)
        // Deleting a missing item is not an error.
        try keychain.deletePassword(for: id)
    }
}
