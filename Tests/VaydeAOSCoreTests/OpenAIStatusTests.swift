import Foundation
import Testing
@testable import VaydeAOSCore

@Suite(.serialized)
struct OpenAIStatusTests {
    @Test func isolatesAPIComponentsFromOverallAndChatGPTHealth() throws {
        let snapshot = try OpenAIStatusSnapshot.decode(Data(#"""
        {"status":{"indicator":"major"},"components":[
          {"name":"Conversations","status":"major_outage"},
          {"name":"Chat Completions","status":"operational"},
          {"name":"Responses","status":"degraded_performance"}
        ]}
        """#.utf8))
        #expect(snapshot.chatCompletions == .operational)
        #expect(snapshot.responses == .degradedPerformance)
    }

    @Test func preservesPublishedStatusBands() throws {
        for (raw, expected, level) in [
            ("operational", OpenAIServiceStatus.operational, 0.0),
            ("degraded_performance", .degradedPerformance, 1.0),
            ("partial_outage", .partialOutage, 2.0),
            ("major_outage", .majorOutage, 3.0)
        ] {
            let status = try JSONDecoder().decode(OpenAIServiceStatus.self, from: Data("\"\(raw)\"".utf8))
            #expect(status == expected)
            #expect(status.disruptionLevel == level)
        }
        #expect(OpenAIServiceStatus.maintenance.disruptionLevel == nil)
        #expect(OpenAIServiceStatus.unknown.disruptionLevel == nil)
    }

    @Test func missingUnknownAndAmbiguousComponentsStayUnavailable() throws {
        for components in [
            "[]",
            #"[{"name":"Responses","status":"future_status"}]"#,
            #"[{"name":"Responses","status":"operational"},{"name":"Responses","status":"major_outage"}]"#
        ] {
            let snapshot = try OpenAIStatusSnapshot.decode(Data("{\"components\":\(components)}".utf8))
            #expect(snapshot.chatCompletions == .unknown)
            #expect(snapshot.responses == .unknown)
        }
        #expect(throws: (any Error).self) {
            try OpenAIStatusSnapshot.decode(Data("{}".utf8))
        }
    }

    @Test func publicFetchHasNoAuthenticationOrConversationAndRejectsHTTPFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicStatusURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenAIStatusClient(session: session)
        let snapshot = try await client.fetch()
        #expect(snapshot.chatCompletions == .operational)
        #expect(snapshot.responses == .partialOutage)

        PublicStatusURLProtocol.responseCode = 503
        defer { PublicStatusURLProtocol.responseCode = 200 }
        do {
            _ = try await client.fetch()
            Issue.record("A failed feed must not produce an operational snapshot")
        } catch {
            #expect((error as? URLError)?.code == .badServerResponse)
        }
    }
}

private final class PublicStatusURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var code = 200
    static var responseCode: Int {
        get { lock.lock(); defer { lock.unlock() }; return code }
        set { lock.lock(); defer { lock.unlock() }; code = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url == OpenAIStatusClient.summaryURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
        #expect(request.httpBodyStream == nil)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"components":[{"name":"Chat Completions","status":"operational"},{"name":"Responses","status":"partial_outage"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
