import Foundation
import Testing
@testable import VaydeAOSCore

struct ConnectionSettingsTests {
    @Test func testLocalDefaultsAreValid() throws {
        #expect(try ConnectionSettings.local.validated() == .local)
    }

    @Test func testReasoningEffortSurvivesValidationAndPersistence() throws {
        for effort in ConnectionSettings.ReasoningEffort.allCases {
            var settings = ConnectionSettings.local
            settings.reasoningEffort = effort
            let normalized = try settings.validated()
            let decoded = try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(normalized))
            #expect(decoded.reasoningEffort == effort)
        }
        let legacy = Data(#"{"baseURL":"http://127.0.0.1:11434/v1","model":"local-model"}"#.utf8)
        #expect(try JSONDecoder().decode(ConnectionSettings.self, from: legacy).reasoningEffort == .automatic)
    }

    @Test func testNormalizationTrimsURLModelAndTrailingSlashes() throws {
        let settings = try ConnectionSettings(
            baseURL: " HTTPS://API.EXAMPLE.COM:443/v1/// \n",
            model: " example-model \n"
        ).validated()
        #expect(settings.baseURL == "https://api.example.com/v1")
        #expect(settings.model == "example-model")
    }

    @Test func testLoopbackHTTPIsAccepted() throws {
        for endpoint in [
            "http://localhost:11434/v1",
            "http://127.0.0.1:11434/v1",
            "http://127.42.0.9/v1",
            "http://[::1]:11434/v1"
        ] {
            _ = try ConnectionSettings(baseURL: endpoint, model: "test").validated()
        }
    }

    @Test func testRemoteHTTPIsRejected() {
        for endpoint in [
            "http://api.example.com/v1",
            "http://192.168.1.10/v1",
            "http://127.0.0.1.example.com/v1",
            "http://[::2]/v1"
        ] {
            assertValidationError(.insecureURL, baseURL: endpoint)
        }
    }

    @Test func testInvalidAndCredentialBearingURLsAreRejected() {
        for endpoint in [
            "", "not a URL", "https://", "ftp://example.com/v1", "https://user:secret@example.com/v1",
            "https://example.com/v1?key=secret", "https://example.com/v1#fragment",
            "https://example.com/v1?", "https://example.com/v1#", "https://example.com:0/v1",
            "https://example.com:65536/v1", "https://example.com:bad/v1", "https://exa mple.com/v1",
            "https://example.com\\v1", "https://./v1"
        ] {
            assertValidationError(.invalidURL, baseURL: endpoint)
        }
    }

    @Test func testBlankOrControlContainingModelIsRejected() {
        for model in ["", " \n\t", "model\ninjected"] {
            assertValidationError(.missingModel, baseURL: "https://example.com/v1", model: model)
        }
    }

    @Test func testMessageCodableRoundTripPreservesIdentityRoleAndText() throws {
        let message = ChatMessage(role: .assistant, content: "A reply\nwith formatting.")
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: data) == message)
    }

    @Test func legacyMessagesKeepUnknownAttributionAndNewMessagesRoundTripIt() throws {
        let original = ChatMessage(role: .assistant, content: "Old response")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "attribution")
        let legacy = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.attribution == nil)
        let attributed = ChatMessage(role: .assistant, content: "New response",
            attribution: ResponseAttribution(provider: .chatGPT, model: "resolved-model", source: .reported, startedNewThread: true))
        #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(attributed)) == attributed)
    }

    private func assertValidationError(
        _ expected: ConnectionSettingsError,
        baseURL: String,
        model: String = "test"
    ) {
        do {
            _ = try ConnectionSettings(baseURL: baseURL, model: model).validated()
            Issue.record("Expected \(expected) for \(baseURL).")
        } catch {
            #expect(error as? ConnectionSettingsError == expected)
        }
    }
}
