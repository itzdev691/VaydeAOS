import Foundation
import Testing
@testable import VaydeAOSCore

@Suite(.serialized)
final class ChatClientTests {
    private var sessions: [URLSession] = []

    deinit {
        for session in sessions { session.invalidateAndCancel() }
        sessions.removeAll()
        StubURLProtocol.configure(handler: nil)
    }

    @Test func testRequestContainsOnlyModelConversationAndStreamFlag() async throws {
        let history = [
            ChatMessage(role: .user, content: "First question"),
            ChatMessage(role: .assistant, content: "First reply"),
            ChatMessage(role: .user, content: "Follow-up\nwith a second line")
        ]
        let client = makeClient { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

            let body = try #require(JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any])
            #expect(Set(body.keys) == ["model", "messages", "stream"])
            #expect(body["model"] as? String == "qwen3.5:9b")
            #expect(body["stream"] as? Bool == false)

            let sentMessages = try #require(body["messages"] as? [[String: String]])
            #expect(sentMessages.count == history.count)
            for (sent, original) in zip(sentMessages, history) {
                #expect(sent == ["role": original.role.rawValue, "content": original.content])
            }
            return .response(200, Self.replyData("The answer"))
        }

        let reply = try await client.reply(to: history, settings: .local, apiKey: nil)
        #expect(reply == "The answer")
    }

    @Test func testMeasuredReplyPreservesProviderTokenUsage() async throws {
        let client = makeClient { _ in
            .response(200, Data(#"{"choices":[{"message":{"content":"Measured reply"}}],"usage":{"prompt_tokens":500,"completion_tokens":120,"total_tokens":620}}"#.utf8))
        }
        let result = try await client.measuredReply(to: [], settings: .local, apiKey: nil)
        #expect(result.content == "Measured reply")
        #expect(result.inputTokens == 500)
        #expect(result.outputTokens == 120)
    }

    @Test func testMissingOrInvalidUsageDoesNotDiscardValidReplies() async throws {
        for usage in ["null", "[]", "{}", "false", #"{"prompt_tokens":-1,"completion_tokens":"invalid"}"#] {
            let body = #"{"choices":[{"message":{"content":"Usable answer"}}],"usage":\#(usage)}"#
            let client = makeClient { _ in .response(200, Data(body.utf8)) }
            let result = try await client.measuredReply(to: [], settings: .local, apiKey: nil)
            #expect(result.content == "Usable answer")
            #expect(result.inputTokens == nil)
            #expect(result.outputTokens == nil)
        }
        let client = makeClient { _ in .response(200, Self.replyData("No usage supplied")) }
        let result = try await client.measuredReply(to: [], settings: .local, apiKey: nil)
        #expect(result.inputTokens == nil)
        #expect(result.outputTokens == nil)
    }

    @Test func testRemoteRequestUsesNormalizedURLAndOptionalBearerKey() async throws {
        let client = makeClient { request in
            #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            return .response(200, Self.replyData("  Text with spacing\n"))
        }

        let reply = try await client.reply(
            to: [ChatMessage(role: .user, content: "Question")],
            settings: ConnectionSettings(baseURL: " HTTPS://API.EXAMPLE.COM:443/v1/// ", model: " example-model "),
            apiKey: " test-key\n"
        )
        #expect(reply == "  Text with spacing\n")
    }

    @Test func testBlankKeyOmitsAuthorization() async throws {
        let client = makeClient { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return .response(200, Self.replyData("Reply"))
        }
        _ = try await client.reply(to: [], settings: .local, apiKey: " \n")
    }

    @Test func testInvalidKeyIsRejectedBeforeSending() async {
        let client = makeClient { _ in
            Issue.record("An invalid key must not be sent.")
            return .response(200, Self.replyData("Reply"))
        }
        await assertError(.invalidAPIKey, client: client, apiKey: "key\ninjected")
    }

    @Test func testHTTPFailuresHaveUsefulErrorCases() async {
        for (status, expected) in [
            (401, ChatClientError.authenticationFailed(401)),
            (403, .authenticationFailed(403)),
            (404, .httpStatus(404)),
            (429, .unclassifiedLimit),
            (500, .httpStatus(500))
        ] {
            let client = makeClient { _ in .response(status, Data()) }
            await assertError(expected, client: client)
            #expect(!(expected.localizedDescription.isEmpty))
        }
    }

    @Test func testQuotaErrorsAreDistinctFromTemporaryRateLimits() async throws {
        for (code, expected) in [
            ("credit_balance_exhausted", ChatClientError.creditsExhausted),
            ("organization_spend_limit_exceeded", .spendLimitExceeded),
            ("project_spend_limit_exceeded", .spendLimitExceeded),
            ("organization_usage_limit_exceeded", .usageLimitExceeded),
            ("insufficient_quota", .quotaExceeded),
            ("usage_limit_exceeded", .quotaExceeded),
            ("unknown_future_code", .quotaExceeded)
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "error": ["code": code, "type": "insufficient_quota", "message": "private-request-content"]
            ])
            let client = makeClient { _ in .response(429, data, ["Retry-After": "10"]) }
            await assertError(expected, client: client)
            #expect(!expected.localizedDescription.contains("private-request-content"))
            #expect(!expected.localizedDescription.contains("Wait at least"))
        }
    }

    @Test func testRateLimitsUseValidRetryDelay() async {
        for code in ["rate_limit_exceeded", "slow_down"] {
            for (header, delay) in [
                ("12", Optional(12)), ("0", Optional(0)), ("-1", nil),
                ("invalid", nil), ("999999999999999999999999999", nil)
            ] {
                let data = Data("{\"error\":{\"code\":\"\(code)\",\"type\":\"rate_limit_error\"}}".utf8)
                let client = makeClient { _ in .response(429, data, ["Retry-After": header]) }
                await assertError(.rateLimited(retryAfterSeconds: delay), client: client)
            }
        }
        let client = makeClient { _ in
            .response(429, Data("{\"error\":{\"code\":null,\"type\":\"rate_limit_error\"}}".utf8))
        }
        await assertError(.rateLimited(retryAfterSeconds: nil), client: client)
    }

    @Test func testUnknown429DoesNotInventAReasonOrExposeProviderText() async {
        for body in [
            "", "not JSON", "{}",
            "{\"error\":{\"code\":123,\"message\":\"private-request-content\"}}",
            "{\"error\":{\"code\":\"future_code\",\"type\":\"future_type\"}}"
        ] {
            let client = makeClient { _ in .response(429, Data(body.utf8), ["Retry-After": "10"]) }
            await assertError(.unclassifiedLimit, client: client)
        }
        #expect(!ChatClientError.unclassifiedLimit.localizedDescription.contains("private-request-content"))
    }

    @Test func testMalformedResponsesAreRejected() async {
        for body in ["not JSON", "{}", "{\"choices\":[{\"message\":{\"content\":[]}}]}"] {
            let client = makeClient { _ in .response(200, Data(body.utf8)) }
            await assertError(.malformedResponse, client: client)
        }
    }

    @Test func testSuccessfulResponseWithNoBodyIsReportedAsEmpty() async {
        let client = makeClient { _ in .response(204, Data()) }
        await assertError(.emptyResponse, client: client)
    }

    @Test func testRedirectDoesNotForwardTheAPIRequest() async {
        let destination = URL(string: "http://remote.example.test/v1/chat/completions")!
        let client = makeClient { request in
            guard request.url?.host == "127.0.0.1" else {
                Issue.record("The API request followed a redirect to another endpoint.")
                return .response(200, Self.replyData("Unexpected redirected response"))
            }
            return .redirect(destination)
        }
        await assertError(.httpStatus(302), client: client, apiKey: "test-key")
    }

    @Test func testMissingAndWhitespaceReplyTextAreRejected() async {
        for body in [
            "{\"choices\":[]}",
            "{\"choices\":[{\"message\":{\"content\":null}}]}",
            "{\"choices\":[{\"message\":{}}]}",
            "{\"choices\":[{\"message\":{\"content\":\"\"}}]}",
            "{\"choices\":[{\"message\":{\"content\":\" \\n\\t \"}}]}"
        ] {
            let client = makeClient { _ in .response(200, Data(body.utf8)) }
            await assertError(.emptyResponse, client: client)
        }
    }

    @Test func testTimeoutAndConnectionFailuresAreReported() async {
        for (code, expected) in [
            (URLError.Code.timedOut, ChatClientError.timedOut),
            (.cannotConnectToHost, .networkUnavailable),
            (.notConnectedToInternet, .networkUnavailable),
            (.secureConnectionFailed, .networkFailure)
        ] {
            let client = makeClient { _ in throw URLError(code) }
            await assertError(expected, client: client)
        }
    }

    @Test(.timeLimit(.minutes(1))) func testCancellationStopsTheRequestAndPropagates() async throws {
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (stopped, stopSignal) = AsyncStream<Void>.makeStream()
        defer {
            startSignal.finish()
            stopSignal.finish()
        }
        let client = makeClient(onStop: { stopSignal.yield(()) }) { _ in
            startSignal.yield(())
            return .pending
        }

        let task = Task {
            try await client.reply(to: [], settings: .local, apiKey: nil)
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Cancellation must propagate.")
        } catch {
            #expect(error is CancellationError)
        }
        var stops = stopped.makeAsyncIterator()
        _ = await stops.next()
    }

    @Test func testInvalidSettingsAreRejectedBeforeSending() async {
        let client = makeClient { _ in
            Issue.record("Invalid connection settings must not be sent.")
            return .response(200, Self.replyData("Reply"))
        }

        do {
            _ = try await client.reply(
                to: [],
                settings: ConnectionSettings(baseURL: "http://remote.example/v1", model: "test"),
                apiKey: nil
            )
            Issue.record("Insecure remote HTTP must be rejected.")
        } catch {
            #expect(error as? ConnectionSettingsError == .insecureURL)
        }
    }

    private func makeClient(
        onStop: (() -> Void)? = nil,
        handler: @escaping (URLRequest) throws -> StubURLProtocol.Result
    ) -> ChatClient {
        StubURLProtocol.configure(handler: handler, onStop: onStop)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        return ChatClient(session: session)
    }

    private func assertError(
        _ expected: ChatClientError,
        client: ChatClient,
        apiKey: String? = nil
    ) async {
        do {
            _ = try await client.reply(to: [], settings: .local, apiKey: apiKey)
            Issue.record("Expected \(expected).")
        } catch {
            #expect(error as? ChatClientError == expected)
        }
    }

    private static func replyData(_ content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }

    private static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Result {
        case response(Int, Data, [String: String] = [:])
        case redirect(URL)
        case pending
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Result)?
    private static var onStop: (() -> Void)?

    static func configure(
        handler: ((URLRequest) throws -> Result)?,
        onStop: (() -> Void)? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        Self.handler = handler
        Self.onStop = onStop
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        do {
            guard let handler else { throw URLError(.unknown) }
            switch try handler(request) {
            case .pending:
                return
            case .redirect(let destination):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": destination.absoluteString]
                )!
                var redirect = request
                redirect.url = destination
                client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case .response(let status, let data, let headers):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers.merging(["Content-Type": "application/json"]) { _, new in new }
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        let onStop = Self.onStop
        Self.lock.unlock()
        onStop?()
    }
}
