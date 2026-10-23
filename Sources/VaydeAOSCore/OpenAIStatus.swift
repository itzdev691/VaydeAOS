import Foundation

/// Public service availability, aggregated across models and tiers by OpenAI.
/// These states do not measure model latency, throughput, or benchmark quality.
public enum OpenAIServiceStatus: String, Decodable, Sendable {
    case operational
    case degradedPerformance = "degraded_performance"
    case partialOutage = "partial_outage"
    case majorOutage = "major_outage"
    case maintenance = "under_maintenance"
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    public var label: String {
        switch self {
        case .operational: return "OPERATIONAL"
        case .degradedPerformance: return "DEGRADED"
        case .partialOutage: return "PARTIAL OUTAGE"
        case .majorOutage: return "MAJOR OUTAGE"
        case .maintenance: return "MAINTENANCE"
        case .unknown: return "UNAVAILABLE"
        }
    }

    /// Ordinal status bands, not a numeric performance score.
    public var disruptionLevel: Double? {
        switch self {
        case .operational: return 0
        case .degradedPerformance: return 1
        case .partialOutage: return 2
        case .majorOutage: return 3
        case .maintenance, .unknown: return nil
        }
    }
}

public struct OpenAIStatusSnapshot: Equatable, Sendable {
    public let chatCompletions: OpenAIServiceStatus
    public let responses: OpenAIServiceStatus

    public static func decode(_ data: Data) throws -> Self {
        struct Component: Decodable {
            let name: String
            let status: OpenAIServiceStatus
        }
        struct Summary: Decodable { let components: [Component] }
        let summary = try JSONDecoder().decode(Summary.self, from: data)
        // Do not use overall page health: it also covers ChatGPT, Ads, and other services.
        func status(_ name: String) -> OpenAIServiceStatus {
            let matches = summary.components.filter { $0.name == name }
            return matches.count == 1 ? matches[0].status : .unknown
        }
        return Self(chatCompletions: status("Chat Completions"), responses: status("Responses"))
    }
}

public struct OpenAIStatusSample: Identifiable, Equatable, Sendable {
    public var id: Date { observedAt }
    public let observedAt: Date
    /// Nil records a failed poll, leaving a gap in both traces.
    public let snapshot: OpenAIStatusSnapshot?

    public init(observedAt: Date, snapshot: OpenAIStatusSnapshot?) {
        self.observedAt = observedAt
        self.snapshot = snapshot
    }
}

public struct OpenAIStatusClient: Sendable {
    public static let summaryURL = URL(string: "https://status.openai.com/api/v2/summary.json")!
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func fetch() async throws -> OpenAIStatusSnapshot {
        var request = URLRequest(url: Self.summaryURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try OpenAIStatusSnapshot.decode(data)
    }
}
