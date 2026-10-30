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
        #expect(session.performanceHistory.map(\.outcome) == [.failed])
        #expect(session.performanceHistory.first?.outputTokensPerWallSecond == nil)
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
        #expect(session.performanceHistory.map(\.outcome) == [.cancelled, .success])
        #expect(session.performanceHistory.allSatisfy { $0.elapsed >= 0 })
        #expect(session.performanceRequestStartedAt == nil)
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
        #expect(session.performanceHistory.isEmpty)
        #expect(session.performanceRequestStartedAt == nil)
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
        #expect(makeSession(client: client).messages.count == 2)
        await client.succeed(at: 1, with: "Follow-up answer")
        await followUpTask.value

        let relaunched = makeSession(client: client)
        #expect(relaunched.messages == session.messages)
        #expect(relaunched.messages.count == 4)
    }

    @Test
    func testChannelReopenTimeoutPreservesAndArchivesDrafts() throws {
        let session = makeSession(client: ControlledChatClient())
        let originalID = session.selectedChatID
        let closed = Date(timeIntervalSinceReferenceDate: 10_000)
        let timeout = ChatSession.chatReopenTimeout
        session.draft = "Keep this unfinished prompt"
        session.closeChatChannel(originalID, at: closed)
        session.prepareChatForOpening(at: closed.addingTimeInterval(timeout - 1))
        #expect(session.selectedChatID == originalID)
        #expect(session.draft == "Keep this unfinished prompt")
        #expect(session.chats.count == 1)

        session.closeChatChannel(originalID, at: closed.addingTimeInterval(timeout))
        let relaunched = makeSession(client: ControlledChatClient())
        relaunched.prepareChatForOpening(at: closed.addingTimeInterval(2 * timeout))
        #expect(relaunched.selectedChatID != originalID)
        #expect(relaunched.draft.isEmpty)
        #expect(relaunched.chats.count == 2)
        #expect(relaunched.chats.first { $0.id == originalID }?.draft == "Keep this unfinished prompt")
        #expect(makeSession(client: ControlledChatClient()).selectedChatID == relaunched.selectedChatID)
    }

    @Test
    func testExplicitSavedChatResumeBypassesTimeoutAndEmptyChatsAreReused() {
        let session = makeSession(client: ControlledChatClient())
        let originalID = session.selectedChatID
        let closed = Date(timeIntervalSinceReferenceDate: 10_000)
        let later = closed.addingTimeInterval(ChatSession.chatReopenTimeout * 2)
        session.closeChatChannel(originalID, at: closed)
        session.prepareChatForOpening(at: later)
        #expect(session.selectedChatID == originalID)
        #expect(session.chats.count == 1)

        session.draft = "Resume this saved chat"
        session.closeChatChannel(originalID, at: closed)
        session.prepareChatForOpening(resuming: true, at: later)
        #expect(session.selectedChatID == originalID)
        #expect(session.draft == "Resume this saved chat")
    }

    @Test
    func testChannelTimeoutIsScopedToTheSelectedWorkspace() {
        let session = makeSession(client: ControlledChatClient())
        let originalWorkspace = session.selectedWorkspaceID
        let originalChat = session.selectedChatID
        let closed = Date(timeIntervalSinceReferenceDate: 10_000)
        session.draft = "First workspace draft"
        session.closeChatChannel(originalChat, at: closed)
        session.createWorkspace(named: "Second")
        let secondChat = session.selectedChatID
        session.prepareChatForOpening(at: closed.addingTimeInterval(ChatSession.chatReopenTimeout))
        #expect(session.selectedChatID == secondChat)
        session.selectWorkspace(originalWorkspace)
        session.prepareChatForOpening(at: closed.addingTimeInterval(ChatSession.chatReopenTimeout))
        #expect(session.selectedChatID != originalChat)
        #expect(session.selectedWorkspaceID == originalWorkspace)
        #expect(session.chats.first { $0.id == originalChat }?.draft == "First workspace draft")
        #expect(session.chats.contains { $0.id == secondChat })
    }

    @Test
    func testChannelTimeoutDoesNotInterruptRunningRequests() async throws {
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        let originalID = session.selectedChatID
        let closed = Date(timeIntervalSinceReferenceDate: 10_000)
        session.draft = "Finish this request"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)
        session.closeChatChannel(originalID, at: closed)
        session.prepareChatForOpening(at: closed.addingTimeInterval(ChatSession.chatReopenTimeout))
        #expect(session.selectedChatID == originalID)
        #expect(session.isSending)
        #expect(session.pendingMessage?.content == "Finish this request")
        await client.succeed(at: 0, with: "Completed")
        await task.value
        #expect(session.messages.map(\.content) == ["Finish this request", "Completed"])
    }

    @Test
    func testNewChatCancelsPendingWorkAndPreservesPreviousChat() async throws {
        let store = LocalStore(directory: directory)
        try store.saveMessages([ChatMessage(role: .user, content: "Old"), ChatMessage(role: .assistant, content: "Answer")])
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        session.draft = "Pending"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)

        let originalID = session.selectedChatID
        session.newChat()
        #expect(session.draft == "")
        #expect(!(session.isSending))
        #expect(session.messages.isEmpty)
        #expect(session.chats.count == 2)
        #expect(session.chats.first { $0.id == originalID }?.messages.count == 2)
        #expect(session.chats.first { $0.id == originalID }?.draft == "Pending")
        #expect(makeSession(client: client).messages.isEmpty)
        await client.succeed(at: 0, with: "Old answer")
        await task.value
        #expect(session.messages.isEmpty)
        #expect(session.draft == "")
    }

    @Test
    func testChatAndWorkspaceSelectionCannotRedirectAnActiveReply() async throws {
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        let originalChat = session.selectedChatID
        let originalWorkspace = session.selectedWorkspaceID
        session.createWorkspace(named: "Other")
        let otherWorkspace = session.selectedWorkspaceID
        let otherChat = session.selectedChatID
        session.selectWorkspace(originalWorkspace)
        session.draft = "Keep this response here"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)
        session.selectChat(otherChat)
        session.selectWorkspace(otherWorkspace)
        session.createWorkspace(named: "Blocked")
        #expect(session.selectedChatID == originalChat)
        #expect(session.selectedWorkspaceID == originalWorkspace)
        #expect(session.workspaces.count == 2)
        await client.succeed(at: 0, with: "Original response")
        await task.value
        session.selectWorkspace(otherWorkspace)
        #expect(session.messages.isEmpty)
        session.selectWorkspace(originalWorkspace)
        #expect(session.messages.map(\.content) == ["Keep this response here", "Original response"])
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
        session.saveDraft()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("chat-library.json").path))
        #expect(try Data(contentsOf: url) == corrupted)
        session.newChat()
        #expect(session.errorMessage == nil)
        #expect(try Data(contentsOf: url) == corrupted)
        #expect(makeSession(client: ControlledChatClient()).messages.isEmpty)
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
        #expect(try Data(contentsOf: url) == corrupted)
        #expect(makeSession(client: ControlledChatClient()).settings == .local)
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
        let contents = try String(contentsOf: directory.appendingPathComponent("chat-library.json"), encoding: .utf8)
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

    @Test
    func testSessionKeySendsWhenKeychainIsUnavailableWithoutPersistingSecret() async throws {
        let client = ControlledChatClient()
        let credentials = RecordingCredentials()
        credentials.failLoading = true
        credentials.failSaving = true
        let session = makeSession(client: client, credentials: credentials)
        let settings = ConnectionSettings(baseURL: "https://api.example.com/v1/", model: "model")
        try session.saveSettings(settings, apiKey: "  session-secret\n", rememberAPIKey: false)
        #expect(session.usesSessionAPIKey(for: settings))
        #expect(credentials.loadedEndpoint == nil)
        #expect(credentials.savedEndpoint == nil)
        #expect(session.notice?.contains("until you quit") == true)
        let saved = try String(contentsOf: directory.appendingPathComponent("chat-library.json"), encoding: .utf8)
        #expect(!saved.contains("session-secret"))

        session.draft = "Question"
        session.send()
        let task = try #require(session.sendTask)
        try await waitForRequests(1, client: client)
        let requests = await client.requests
        #expect(requests[0].apiKey == "session-secret")
        await client.succeed(at: 0, with: "Answer")
        await task.value
        #expect(credentials.loadedEndpoint == nil)

        let restarted = makeSession(client: ControlledChatClient(), credentials: credentials)
        #expect(!restarted.usesSessionAPIKey(for: settings))
        #expect(throws: (any Error).self) { try restarted.apiKey(for: settings) }
    }

    @Test
    func testSessionKeyIsScopedToNormalizedEndpointAndPreservesSavedKey() throws {
        let credentials = RecordingCredentials()
        credentials.value = "existing-key"
        let session = makeSession(client: ControlledChatClient(), credentials: credentials)
        let endpoint = ConnectionSettings(baseURL: "https://API.example.com:443/v1/", model: "model")
        let normalized = try endpoint.validated()
        try session.saveSettings(endpoint, apiKey: "session-key", rememberAPIKey: false)
        #expect(try session.apiKey(for: normalized) == "session-key")
        #expect(try session.apiKey(for: .local) == "existing-key")
        #expect(credentials.value == "existing-key")

        // An explicit blank session key must not fall back to a stored credential.
        try session.saveSettings(normalized, apiKey: "", rememberAPIKey: false)
        #expect(try session.apiKey(for: endpoint) == nil)
        #expect(credentials.value == "existing-key")
    }

    @Test
    func testSessionKeySurvivesFailedKeychainSaveAndClearsAfterSuccessfulSave() throws {
        let credentials = RecordingCredentials()
        let session = makeSession(client: ControlledChatClient(), credentials: credentials)
        try session.saveSettings(.local, apiKey: "session-key", rememberAPIKey: false)
        credentials.failSaving = true
        #expect(throws: (any Error).self) { try session.saveSettings(.local, apiKey: "persistent-key") }
        #expect(try session.apiKey(for: .local) == "session-key")
        #expect(session.notice == nil)

        credentials.failSaving = false
        try session.saveSettings(.local, apiKey: "persistent-key")
        #expect(!session.usesSessionAPIKey(for: .local))
        #expect(try session.apiKey(for: .local) == "persistent-key")
        #expect(credentials.value == "persistent-key")
    }

    @Test
    func testFailedSettingsWriteDoesNotActivateSessionKey() throws {
        let credentials = RecordingCredentials()
        credentials.value = "existing-key"
        let session = makeSession(client: ControlledChatClient(), credentials: credentials)
        try Data("blocks storage".utf8).write(to: directory)
        #expect(throws: (any Error).self) {
            try session.saveSettings(.local, apiKey: "session-key", rememberAPIKey: false)
        }
        #expect(!session.usesSessionAPIKey(for: .local))
        #expect(try session.apiKey(for: .local) == "existing-key")
        #expect(session.notice == nil)
    }

    @Test func testPerformanceReceivesUsageAndUsesEndToEndTime() async throws {
        let session = ChatSession(client: UsageChatClient(), store: LocalStore(directory: directory),
                                  credentials: RecordingCredentials())
        session.draft = "Measure a request"
        session.send()
        let task = try #require(session.sendTask)
        await task.value
        let record = try #require(session.performanceHistory.first)
        #expect(record.outcome == .success)
        #expect(record.inputTokens == 10)
        #expect(record.outputTokens == 20)
        #expect(record.elapsed > 0)
        #expect(record.outputTokensPerWallSecond == 20 / record.elapsed)
        #expect(session.messages.last?.content == "Measured answer")
        #expect(session.performanceRequestStartedAt == nil)
        let relaunched = ChatSession(client: UsageChatClient(), store: LocalStore(directory: directory),
                                     credentials: RecordingCredentials())
        #expect(relaunched.performanceHistory.isEmpty)
    }

    @Test func testPerformanceHistoryIsBoundedAndScopedToConnection() async throws {
        let client = ControlledChatClient()
        let session = makeSession(client: client)
        for index in 0..<62 {
            session.draft = "Request \(index)"
            session.send()
            let task = try #require(session.sendTask)
            try await waitForRequests(index + 1, client: client)
            await client.succeed(at: index, with: "Answer")
            await task.value
        }
        #expect(session.performanceHistory.count == 60)
        #expect(Set(session.performanceHistory.map(\.id)).count == 60)
        #expect(session.performanceHistory.allSatisfy { $0.outcome == .success && $0.outputTokens == nil })
        var changed = session.settings
        changed.model = "another-model"
        try session.saveSettings(changed, apiKey: "", rememberAPIKey: false)
        #expect(session.performanceHistory.isEmpty)
    }

    private func makeSession(client: ControlledChatClient, credentials: RecordingCredentials = RecordingCredentials()) -> ChatSession {
        ChatSession(client: client, store: LocalStore(directory: directory), credentials: credentials)
    }

    private func waitForRequests(_ count: Int, client: ControlledChatClient) async throws {
        // Observe the mock's registration directly instead of racing a two-second
        // polling deadline against unrelated work on the shared main actor.
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await client.waitForRequests(count) }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw TestFailure.failed
            }
            do { _ = try await group.next() }
            catch {
                if error is TestFailure { Issue.record("Timed out waiting for request \(count)") }
                throw error
            }
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
    private var requestWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, Error>)] = [:]

    func waitForRequests(_ count: Int) async throws {
        try Task.checkCancellation()
        guard requests.count < count else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requestWaiters[id] = (count, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        requestWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    func reply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> String {
        let index = requests.count
        requests.append(Request(messages: messages, settings: settings, apiKey: apiKey))
        // Deliberately ignores task cancellation to exercise stale-response protection.
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
            let ready = requestWaiters.keys.filter { requestWaiters[$0]!.count <= requests.count }
            for id in ready { requestWaiters.removeValue(forKey: id)?.continuation.resume() }
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
    var failLoading = false

    func load(for endpoint: String) throws -> String? {
        loadedEndpoint = endpoint
        if failLoading { throw TestFailure.failed }
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

private struct UsageChatClient: ChatServing {
    func reply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> String {
        "Measured answer"
    }
    func measuredReply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> ChatReply {
        ChatReply(content: "Measured answer", inputTokens: 10, outputTokens: 20)
    }
}
