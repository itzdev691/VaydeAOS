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

/// A visible, recoverable attempt, kept separate from confirmed model history.
public struct InterruptedTurn: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { message.id }
    public let message: ChatMessage
    public let originalDraft: String
    public let response: ChatMessage?
    public let afterMessageCount: Int
    public let wasCancelled: Bool
}
