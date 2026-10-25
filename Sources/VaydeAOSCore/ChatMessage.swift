import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let content: String
    public let attribution: ResponseAttribution?

    public init(id: UUID = UUID(), role: MessageRole, content: String, attribution: ResponseAttribution? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.attribution = attribution
    }
}

public struct ResponseAttribution: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case reported, runtimeSelected, requested }
    public let provider: ConnectionSettings.Provider
    public let model: String
    public let source: Source
    public let startedNewThread: Bool

    public init(provider: ConnectionSettings.Provider, model: String, source: Source, startedNewThread: Bool = false) {
        self.provider = provider; self.model = model; self.source = source; self.startedNewThread = startedNewThread
    }
    public var label: String {
        let providerName = provider == .chatGPT ? "ChatGPT" : "API"
        let qualification = source == .reported ? "" : source == .runtimeSelected ? " (runtime selection)" : " (requested; unreported)"
        return "\(providerName) / \(model)\(qualification)"
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
