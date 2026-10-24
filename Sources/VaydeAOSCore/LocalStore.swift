import Foundation

/// Stores app preferences and completed chat turns. Credentials belong in Keychain.
public struct LocalStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VaydeAOS", isDirectory: true)
    }

    public func loadSettings() throws -> ConnectionSettings? {
        try load(ConnectionSettings.self, from: "settings.json")
    }

    public func saveSettings(_ settings: ConnectionSettings) throws {
        try save(settings, to: "settings.json")
    }

    public func loadMessages() throws -> [ChatMessage] {
        try load([ChatMessage].self, from: "conversation.json") ?? []
    }

    public func saveMessages(_ messages: [ChatMessage]) throws {
        try save(messages, to: "conversation.json")
    }

    func load<Value: Decodable>(_ type: Value.Type, from filename: String) throws -> Value? {
        let url = directory.appendingPathComponent(filename)
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save<Value: Encodable>(_ value: Value, to filename: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
