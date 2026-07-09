import Foundation
import Testing

@testable import Connections

@Suite struct LabelStoreTests {
    @Test func roundtripsLabels() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-labels-\(UUID().uuidString)/labels.json")
        let store = LabelStore(fileURL: file)

        #expect(try store.load().isEmpty)

        let labels = [
            ConnectionLabel(name: "Production", colorTag: .red),
            ConnectionLabel(name: "Staging", colorTag: .orange),
        ]
        try store.save(labels)
        #expect(try store.load() == labels)

        // Overwrite persists deletions too.
        try store.save([labels[0]])
        #expect(try store.load() == [labels[0]])
    }

    @Test func legacyColorTagDecodesButDoesNotEncode() throws {
        // Old profiles carried a colorTag; it must decode into legacyColorTag
        // and never be written back out.
        let legacyJSON = """
            {"id": "\(UUID().uuidString)", "name": "old", "driverID": "postgres",
             "tls": "preferred", "credentialSource": {"none": {}},
             "colorTag": "red"}
            """
        let profile = try JSONDecoder().decode(
            ConnectionProfile.self, from: Data(legacyJSON.utf8))
        #expect(profile.legacyColorTag == .red)

        let encoded = try JSONEncoder().encode(profile)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("colorTag"))
    }
}
