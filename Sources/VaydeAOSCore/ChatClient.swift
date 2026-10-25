import Foundation

public protocol ChatServing: Sendable {
    func reply(
        to messages: [ChatMessage],
        settings: ConnectionSettings,
        apiKey: String?
    ) async throws -> String

    func measuredReply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> ChatReply
}

public extension ChatServing {
    func measuredReply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> ChatReply {
        ChatReply(content: try await reply(to: messages, settings: settings, apiKey: apiKey))
    }
}

public struct ChatClient: ChatServing {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func reply(
        to messages: [ChatMessage],
        settings: ConnectionSettings,
        apiKey: String?
    ) async throws -> String {
        try await measuredReply(to: messages, settings: settings, apiKey: apiKey).content
    }

    public func measuredReply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> ChatReply {
        try Task.checkCancellation()
        let settings = try settings.validated()
        guard settings.provider == .compatibleAPI else {
            throw ChatGPTHelperError(code: "wrong_provider", message: "ChatGPT plan requests require the ChatGPT provider.")
        }
        guard let endpoint = URL(string: settings.baseURL + "/chat/completions") else {
            throw ConnectionSettingsError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            guard !key.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            }) else {
                throw ChatClientError.invalidAPIKey
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(CompletionRequest(
            model: settings.model,
            messages: messages.map { RequestMessage(role: $0.role, content: $0.content) },
            stream: false,
            reasoningEffort: settings.reasoningEffort.requestValue
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: PrivateRequestDelegate())
        } catch {
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let error = error as? URLError {
                if error.code == .timedOut {
                    throw ChatClientError.timedOut
                }
                switch error.code {
                case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                     .dnsLookupFailed, .networkConnectionLost, .dataNotAllowed,
                     .resourceUnavailable:
                    throw ChatClientError.networkUnavailable
                default:
                    break
                }
            }
            throw ChatClientError.networkFailure
        }

        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatClientError.malformedResponse
        }
        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw ChatClientError.authenticationFailed(httpResponse.statusCode)
        case 429:
            throw Self.limitError(data: data, response: httpResponse)
        default:
            throw ChatClientError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else { throw ChatClientError.emptyResponse }

        let completion: CompletionResponse
        do {
            completion = try JSONDecoder().decode(CompletionResponse.self, from: data)
        } catch {
            throw ChatClientError.malformedResponse
        }
        guard let content = completion.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatClientError.emptyResponse
        }
        return ChatReply(content: content, inputTokens: completion.usage?.promptTokens,
            outputTokens: completion.usage?.completionTokens,
            attribution: ResponseAttribution(provider: .compatibleAPI, model: completion.model ?? settings.model,
                                             source: completion.model == nil ? .requested : .reported))
    }

    private static func limitError(data: Data, response: HTTPURLResponse) -> ChatClientError {
        // Read only structured codes. Provider messages may echo request content or credentials.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String
        let type = error?["type"] as? String
        switch code {
        case "credit_balance_exhausted":
            return .creditsExhausted
        case "organization_spend_limit_exceeded", "project_spend_limit_exceeded":
            return .spendLimitExceeded
        case "organization_usage_limit_exceeded":
            return .usageLimitExceeded
        case "insufficient_quota", "usage_limit_exceeded":
            return .quotaExceeded
        default:
            break
        }
        if type == "insufficient_quota" { return .quotaExceeded }
        if code == "rate_limit_exceeded" || code == "slow_down" || type == "rate_limit_error" {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .flatMap { $0 >= 0 ? $0 : nil }
            return .rateLimited(retryAfterSeconds: retryAfter)
        }
        return .unclassifiedLimit
    }
}

final class PrivateRequestDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum ChatClientError: LocalizedError, Equatable, Sendable {
    case invalidAPIKey
    case authenticationFailed(Int)
    case httpStatus(Int)
    case creditsExhausted
    case spendLimitExceeded
    case usageLimitExceeded
    case quotaExceeded
    case rateLimited(retryAfterSeconds: Int?)
    case unclassifiedLimit
    case timedOut
    case networkUnavailable
    case networkFailure
    case malformedResponse
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "The API key must not contain spaces or control characters."
        case .authenticationFailed(let status):
            return "The API rejected authentication (HTTP \(status)). Check the saved API key."
        case .httpStatus(let status):
            return "The API returned HTTP \(status). Check the base URL, model, and server status."
        case .creditsExhausted:
            return "API credits are exhausted (HTTP 429). Add credits in the API provider's billing settings before retrying."
        case .spendLimitExceeded:
            return "An API project or organization spend limit was reached (HTTP 429). Check the provider's billing and spending limits before retrying."
        case .usageLimitExceeded:
            return "The organization's API usage limit was reached (HTTP 429). Check the provider's usage limits before retrying."
        case .quotaExceeded:
            return "API quota is unavailable or exhausted (HTTP 429). Check API billing, credits, and usage limits. Repeated retries will not restore quota."
        case .rateLimited(let seconds):
            if let seconds {
                return "The API rate limit was reached (HTTP 429). Wait at least \(seconds) seconds before retrying."
            }
            return "The API rate limit was reached (HTTP 429). Wait before retrying and reduce request frequency or conversation size."
        case .unclassifiedLimit:
            return "The API returned HTTP 429 without a recognized error code. This may be a temporary rate limit or exhausted quota. Check the provider's API billing and limits."
        case .timedOut:
            return "The API request timed out. The model may still be loading."
        case .networkUnavailable:
            return "Could not reach the API. Check the base URL and make sure the server is running."
        case .networkFailure:
            return "The API connection failed. Check the network and server status."
        case .malformedResponse:
            return "The API returned an invalid chat response. Use an OpenAI-compatible chat endpoint."
        case .emptyResponse:
            return "The API returned no reply text."
        }
    }
}

private struct CompletionRequest: Encodable {
    let model: String
    let messages: [RequestMessage]
    let stream: Bool
    let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case reasoningEffort = "reasoning_effort"
    }
}

private struct RequestMessage: Encodable {
    let role: MessageRole
    let content: String
}

private struct CompletionResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?
    let model: String?

    private enum CodingKeys: String, CodingKey { case choices, usage, model }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choices = try container.decode([Choice].self, forKey: .choices)
        // Optional telemetry must never discard an otherwise valid reply.
        usage = try? container.decode(Usage.self, forKey: .usage)
        let reported = try? container.decode(String.self, forKey: .model)
        model = reported.flatMap { value in
            value.isEmpty || value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? nil : value
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens", completionTokens = "completion_tokens"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            promptTokens = (try? container.decode(Int.self, forKey: .promptTokens)).flatMap { $0 >= 0 ? $0 : nil }
            completionTokens = (try? container.decode(Int.self, forKey: .completionTokens)).flatMap { $0 >= 0 ? $0 : nil }
        }
    }

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
