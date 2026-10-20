import Foundation

public protocol ChatServing: Sendable {
    func reply(
        to messages: [ChatMessage],
        settings: ConnectionSettings,
        apiKey: String?
    ) async throws -> String
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
        try Task.checkCancellation()
        let settings = try settings.validated()
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
            stream: false
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
        return content
    }
}

private final class PrivateRequestDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
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
}

private struct RequestMessage: Encodable {
    let role: MessageRole
    let content: String
}

private struct CompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
