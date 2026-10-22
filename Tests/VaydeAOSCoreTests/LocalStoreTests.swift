import Foundation
import Testing
@testable import VaydeAOSCore

@Suite("Local conversation storage")
final class LocalStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test
    func testMissingStoreStartsWithoutSettingsOrMessages() throws {
        let store = LocalStore(directory: directory)
        #expect(try store.loadSettings() == nil)
        #expect(try store.loadMessages() == [])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func testSettingsAndCompletedTurnsRoundTripIndependently() throws {
        let store = LocalStore(directory: directory)
        let settings = ConnectionSettings(baseURL: "http://localhost:11434/v1", model: "local-model")
        let messages = [
            ChatMessage(role: .user, content: "Remember the café"),
            ChatMessage(role: .assistant, content: "Remembered.")
        ]

        try store.saveSettings(settings)
        try store.saveMessages(messages)

        #expect(try store.loadSettings() == settings)
        #expect(try store.loadMessages() == messages)
        try store.saveMessages([])
        #expect(try store.loadMessages() == [])
        #expect(try store.loadSettings() == settings)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("conversation.json").path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func testInvalidJSONIsReportedAndPreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let badData = Data("not json".utf8)
        let url = directory.appendingPathComponent("conversation.json")
        try badData.write(to: url)
        let store = LocalStore(directory: directory)

        #expect(throws: (any Error).self) { try store.loadMessages() }
        #expect(try Data(contentsOf: url) == badData)
    }

    @Test
    func testSaveReportsAnUnusableDirectory() throws {
        try Data("a file blocks the storage directory".utf8).write(to: directory)
        let store = LocalStore(directory: directory)

        #expect(throws: (any Error).self) { try store.saveMessages([]) }
        #expect(throws: (any Error).self) { try store.saveSettings(.local) }
        #expect(try String(contentsOf: directory, encoding: .utf8) == "a file blocks the storage directory")
    }
}
