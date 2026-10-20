import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let content: String

    public init(id: UUID = UUID(), role: MessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}
