import Foundation
import Testing
@testable import VaydeAOSCore

@MainActor
@Suite("Chat state and recovery")
final class ChatSessionTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test
    func testEmptyAndOverlappingSendsAreIgnored() async throws {
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        session.draft = " \n "
        session.send()
        #expect(!(session.isSending))
        #expect(session.sendTask == nil)

        session.draft = "First prompt"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)
        session.draft = "Another prompt"
        session.send()

        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(session.pendingMessage?.content == "First prompt")
        #expect(session.messages.isEmpty)
        #expect(!(session.canSend))

        await client.succeed(at: 0, with: "First answer")
        await task.value
        #expect(session.messages.map(\.content) == ["First prompt", "First answer"])
        #expect(session.draft == "Another prompt")
        #expect(!(session.isSending))
    }

    @Test
    func testFailureRestoresOriginalDraftAndPreservesCompletedHistory() async throws {
        let store = LocalStore(directory: directory)
        let history = [ChatMessage(role: .user, content: "Earlier"), ChatMessage(role: .assistant, content: "Answer")]
        try store.saveMessages(history)
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        session.draft = "  Retry this prompt\n"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)
        await client.fail(at: 0)
        await task.value

        #expect(session.draft == "  Retry this prompt\n")
        #expect(session.messages == history)
        #expect(try store.loadMessages() == history)
        #expect(session.pendingMessage == nil)
        #expect(!(session.isSending))
        #expect(session.errorMessage != nil)
        #expect(session.canSend)
    }

    @Test
    func testStopAllowsImmediateResendAndIgnoresLateOldResponse() async throws {
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        session.draft = "Cancelled prompt"
        session.send()
        let cancelledTask = try #require(session.sendTask)
        try await waitForRequests(1, client: client)

        session.stop()
        #expect(!(session.isSending))
        #expect(session.pendingMessage == nil)
        #expect(session.errorMessage == nil)
        #expect(session.notice != nil)
        #expect(session.draft == "Cancelled prompt")
        #expect(session.canSend)

        session.draft = "New prompt"
        session.send()
        let currentTask = try #require(session.sendTask)
        try await waitForRequests(2, client: client)
        await client.succeed(at: 0, with: "Late cancelled answer")
        await cancelledTask.value

        #expect(session.isSending)
        #expect(session.pendingMessage?.content == "New prompt")
        #expect(session.messages.isEmpty)
        #expect(session.errorMessage == nil)

        await client.succeed(at: 1, with: "Current answer")
        await currentTask.value
        #expect(session.messages.map(\.content) == ["New prompt", "Current answer"])
        #expect(!(session.isSending))
    }

    @Test
    func testImmediateStopDoesNotStartClientWork() async throws {
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        session.draft = "Stop before the request starts"
        session.send()
        let task = try #require(session.sendTask)
        session.stop()
        await task.value

        let requests = await client.requests
        #expect(requests.isEmpty)
        #expect(session.draft == "Stop before the request starts")
        #expect(session.errorMessage == nil)
        #expect(session.canSend)
    }

    @Test(arguments: [false, true])
    func testCancellationFromClientIsANoticeInsteadOfAFailure(usesURLCancellation: Bool) async throws {
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        session.draft = "Try again"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)
        await client.cancel(at: 0, usesURLCancellation: usesURLCancellation)
        await task.value

        #expect(session.draft == "Try again")
        #expect(session.messages.isEmpty)
        #expect(session.errorMessage == nil)
        #expect(session.notice != nil)
        #expect(session.canSend)
    }

    @Test
    func testFollowUpIncludesCompletedTurnsAndHistorySurvivesRelaunch() async throws {
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        session.draft = "First question"
        session.send()
        let firstTask = try #require(session.sendTask)
        try await waitForRequests(1, client: client)
        await client.succeed(at: 0, with: "First answer")
        await firstTask.value

        session.draft = "Follow-up"
        session.send()
        let followUpTask = try #require(session.sendTask)
        try await waitForRequests(2, client: client)
        let requests = await client.requests
        #expect(requests[1].messages.map(\.content) == ["First question", "First answer", "Follow-up"])
        #expect(requests[1].messages.map(\.role) == [.user, .assistant, .user])
        #expect(try LocalStore(directory: directory).loadMessages().count == 2)
        await client.succeed(at: 1, with: "Follow-up answer")
        await followUpTask.value

        let relaunched = makeSession(client: client)
        #expect(relaunched.messages == session.messages)
        #expect(relaunched.messages.count == 4)
    }

    @Test
    func testNewChatCancelsPendingWorkAndClearsDraftAndSavedTurns() async throws {
        let store = LocalStore(directory: directory)
        try store.saveMessages([ChatMessage(role: .user, content: "Old"), ChatMessage(role: .assistant, content: "Answer")])
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        session.draft = "Pending"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)

        session.newChat()
        #expect(session.draft == "")
        #expect(!(session.isSending))
        #expect(session.messages.isEmpty)
        #expect(try store.loadMessages() == [])
        await client.succeed(at: 0, with: "Old answer")
        await task.value
        #expect(session.messages.isEmpty)
        #expect(session.draft == "")
    }

    @Test
    func testUnreadableConversationIsPreservedUntilNewChat() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("conversation.json")
        let corrupted = Data("broken conversation".utf8)
        try corrupted.write(to: url)
        let session = makeSession(client: ControlledChatClient())
        session.draft = "A prompt"

        #expect(session.errorMessage != nil)
        #expect(!(session.canSend))
        session.dismissError()
        #expect(session.errorMessage != nil)
        session.send()
        #expect(try Data(contentsOf: url) == corrupted)
        session.newChat()
        #expect(session.errorMessage == nil)
        #expect(try LocalStore(directory: directory).loadMessages() == [])
        session.draft = "A fresh prompt"
        #expect(session.canSend)
    }

    @Test
    func testUnreadableSettingsArePreservedUntilExplicitSave() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        let corrupted = Data("broken settings".utf8)
        try corrupted.write(to: url)
        let session = makeSession(client: ControlledChatClient())
        session.draft = "A prompt"
        #expect(!(session.canSend))
        session.newChat()
        #expect(try Data(contentsOf: url) == corrupted)
        #expect(session.errorMessage != nil)

        try session.saveSettings(.local, apiKey: "")
        #expect(try LocalStore(directory: directory).loadSettings() == .local)
        session.draft = "A prompt"
        #expect(session.canSend)
    }

    @Test
    func testSettingsRejectChangesDuringRequestAndUseNormalizedCredentialScope() async throws {
        let client = ControlledChatClient()
        let credentials = RecordingCredentials()
        let session = makeSession(client: client, credentials: credentials)
        let settings = ConnectionSettings(baseURL: "http://localhost:11434/v1/", model: "another-model")
        let normalized = try settings.validated()
        try session.saveSettings(settings, apiKey: "  private-key\n")
        #expect(session.settings == normalized)
        #expect(credentials.savedEndpoint == normalized.baseURL)
        #expect(try session.apiKey(for: settings) == "private-key")
        #expect(credentials.loadedEndpoint == normalized.baseURL)
        let contents = try String(contentsOf: directory.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(!(contents.contains("private-key")))

        session.draft = "Question"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)
        #expect(throws: (any Error).self) { try session.saveSettings(.local, apiKey: "different-key") }
        #expect(session.settings == normalized)
        #expect(credentials.value == "private-key")
        let requests = await client.requests
        #expect(requests[0].settings == normalized)
        #expect(requests[0].apiKey == "private-key")
        await client.succeed(at: 0, with: "Answer")
        await task.value
    }

    @Test
    func testReplyRemainsVisibleWhenSavingFails() async throws {
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        // The directory becomes unusable only after loading succeeded.
        try Data("blocks storage".utf8).write(to: directory)
        session.draft = "Question"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)
        await client.succeed(at: 0, with: "Answer")
        await task.value

        #expect(session.messages.map(\.content) == ["Question", "Answer"])
        #expect(!(session.isSending))
        #expect(session.errorMessage != nil)
        #expect(session.errorMessage?.contains("could not be saved") == true)
        #expect(try String(contentsOf: directory, encoding: .utf8) == "blocks storage")
    }

    @Test
    func testCredentialOrSettingsSaveFailureDoesNotReportSuccess() throws {
        let credentials = RecordingCredentials()
        let session = makeSession(client: ControlledChatClient(), credentials: credentials)
        let settings = ConnectionSettings(baseURL: "http://localhost:11434/v1", model: "other")
        credentials.failSaving = true
        #expect(throws: (any Error).self) { try session.saveSettings(settings, apiKey: "key") }
        #expect(session.settings == .local)
        #expect(session.notice == nil)
        #expect(try LocalStore(directory: directory).loadSettings() == nil)

        credentials.failSaving = false
        try Data("blocks storage".utf8).write(to: directory)
        #expect(throws: (any Error).self) { try session.saveSettings(settings, apiKey: "key") }
        #expect(session.settings == .local)
        #expect(session.notice == nil)
    }

    @Test
    func testFailedSettingsSaveClearsAnEarlierSuccessNotice() throws {
        let credentials = RecordingCredentials()
        let session = makeSession(client: ControlledChatClient(), credentials: credentials)
        try session.saveSettings(.local, apiKey: "")
        #expect(session.notice == "Settings saved.")

        credentials.failSaving = true
        #expect(throws: (any Error).self) { try session.saveSettings(.local, apiKey: "a-key") }
        #expect(session.notice == nil)
    }

    private func makeSession(client: ControlledChatClient, credentials: RecordingCredentials = RecordingCredentials()) -> ChatSession {
        ChatSession(client: client, store: LocalStore(directory: directory), credentials: credentials)
    }

    private func waitForRequests(_ count: Int, client: ControlledChatClient) async throws {
        let deadline = Date().addingTimeInterval(2)
        while await client.requests.count < count {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for request \(count)")
                throw TestFailure.failed
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private actor ControlledChatClient: ChatServing {
    struct Request: Sendable {
        let messages: [ChatMessage]
        let settings: ConnectionSettings
        let apiKey: String?
    }

    private(set) var requests: [Request] = []
    private var continuations: [Int: CheckedContinuation<String, Error>] = [:]

    func reply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> String {
        let index = requests.count
        requests.append(Request(messages: messages, settings: settings, apiKey: apiKey))
        // Deliberately ignores task cancellation to exercise stale-response protection.
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func succeed(at index: Int, with response: String) {
        continuations.removeValue(forKey: index)?.resume(returning: response)
    }

    func fail(at index: Int) {
        continuations.removeValue(forKey: index)?.resume(throwing: TestFailure.failed)
    }

    func cancel(at index: Int, usesURLCancellation: Bool) {
        let error: any Error = usesURLCancellation ? URLError(.cancelled) : CancellationError()
        continuations.removeValue(forKey: index)?.resume(throwing: error)
    }
}

private final class RecordingCredentials: CredentialStoring {
    var value: String?
    var savedEndpoint: String?
    var loadedEndpoint: String?
    var failSaving = false

    func load(for endpoint: String) throws -> String? {
        loadedEndpoint = endpoint
        return value
    }

    func save(_ key: String, for endpoint: String) throws {
        if failSaving { throw TestFailure.failed }
        value = key.isEmpty ? nil : key
        savedEndpoint = endpoint
    }
}

private enum TestFailure: Error {
    case failed
}
