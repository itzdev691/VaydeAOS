import Foundation

/// API-supplied token usage. Optional values stay unavailable when omitted by a provider.
public struct ChatReply: Sendable {
    public let content: String
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(content: String, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.content = content
        self.inputTokens = inputTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.outputTokens = outputTokens.flatMap { $0 >= 0 ? $0 : nil }
    }
}

/// Session-only timing metadata; never contains prompts, replies, or credentials.
public struct RequestPerformance: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Sendable { case success, failed, cancelled }
    public let id: UUID
    public let elapsed: TimeInterval
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let outcome: Outcome

    public init(id: UUID = UUID(), elapsed: TimeInterval, inputTokens: Int? = nil,
                outputTokens: Int? = nil, outcome: Outcome) {
        self.id = id
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.inputTokens = inputTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.outputTokens = outputTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.outcome = outcome
    }

    /// Effective completion throughput including network, queueing, and prompt processing.
    /// This is not a measurement of generation-only speed or time to first token.
    public var outputTokensPerWallSecond: Double? {
        guard outcome == .success, elapsed > 0, let outputTokens else { return nil }
        let value = Double(outputTokens) / elapsed
        return value.isFinite ? value : nil
    }
}
