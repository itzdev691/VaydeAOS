import Foundation
import Testing
@testable import VaydeAOSCore

@Suite("ChatGPT provider and bridge")
struct ChatGPTTests {
    @Test func legacySettingsDecodeWithoutChangingProvider() throws {
        let saved = Data(#"{"baseURL":"http://127.0.0.1:11434/v1","model":"local-model"}"#.utf8)
        let settings = try JSONDecoder().decode(ConnectionSettings.self, from: saved)
        #expect(settings.provider == .compatibleAPI)
        #expect(settings.activeModel == "local-model")
    }

    @Test func planSettingsPreserveAPIConnectionAcrossRoundTrip() throws {
        let settings = ConnectionSettings(baseURL: "https://api.example.com/v1/", model: "api-model", provider: .chatGPT, chatGPTModel: " plan-model ")
        let normalized = try settings.validated()
        #expect(normalized.baseURL == "https://api.example.com/v1")
        #expect(normalized.model == "api-model")
        #expect(normalized.activeModel == "plan-model")
        #expect(try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(normalized)) == normalized)
        #expect(try ConnectionSettings(baseURL: settings.baseURL, model: settings.model, provider: .chatGPT).validated().activeModel == "ChatGPT default")
    }

    @Test func APIClientRefusesPlanSettingsBeforeNetwork() async throws {
        let settings = ConnectionSettings(baseURL: "https://api.openai.com/v1", model: "api-model", provider: .chatGPT, chatGPTModel: "plan-model")
        do {
            _ = try await ChatClient().reply(to: [], settings: settings, apiKey: "must-not-send")
            Issue.record("API client accepted ChatGPT settings")
        } catch { #expect((error as? ChatGPTHelperError)?.code == "wrong_provider") }
    }

    @Test @MainActor func reasoningSelectionPersistsWithoutAccessingCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = ForbiddenAPICredentials()
        let store = LocalStore(directory: directory)
        let session = ChatSession(store: store, credentials: credentials)
        try session.setReasoningEffort(.medium)
        let restored = ChatSession(store: store, credentials: credentials)
        #expect(restored.settings.reasoningEffort == .medium)
        #expect(credentials.calls == 0)
    }

    @Test @MainActor func identityWithoutPlanPermissionCannotBeSavedOrSent() async throws {
        let helper = FakePlanHelper(sharing: false)
        let account = ChatGPTAccount(helper: helper)
        account.refresh()
        try await waitUntil { !account.isBusy }
        #expect(account.session.status == "connected")
        #expect(!account.session.canUsePlan)
        do {
            _ = try await account.reply(to: [ChatMessage(role: .user, content: "Blocked")], model: "plan-model") { _ in }
            Issue.record("Legacy helper accepted identity-only consent")
        } catch { #expect((error as? ChatGPTHelperError)?.code == "sign_in_required") }
        #expect(await helper.requests.allSatisfy { $0.method != "models" && $0.method != "reply" })
    }

    @Test func missingBundleHelperFailsWithoutLaunchingSystemNode() async {
        let helper = ChatGPTHelper(helperDirectory: URL(fileURLWithPath: "/does-not-exist"))
        do { _ = try await helper.request(ChatGPTHelperRequest(method: "state")); Issue.record("Missing helper accepted") }
        catch { #expect((error as? ChatGPTHelperError)?.code == "helper_unavailable") }
    }

    @Test func processBridgeReassemblesFramesAndRestartsAfterCrash() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let helper = ChatGPTHelper(helperDirectory: fixture.directory, storageDirectory: fixture.directory.appendingPathComponent("storage"))
        let response = try await helper.request(ChatGPTHelperRequest(method: "state"))
        #expect(response.session?.status == "disconnected")
        do { _ = try await helper.request(ChatGPTHelperRequest(method: "crash")); Issue.record("Crash reported success") }
        catch { #expect((error as? ChatGPTHelperError)?.code == "helper_stopped") }
        let restarted = try await helper.request(ChatGPTHelperRequest(method: "state"))
        #expect(restarted.session?.sharing == false)
        await helper.shutdown()
    }

    @Test func malformedProtocolFailsPendingRequestsAndCanRestart() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let helper = ChatGPTHelper(helperDirectory: fixture.directory)
        do { _ = try await helper.request(ChatGPTHelperRequest(method: "malformed")); Issue.record("Malformed data accepted") }
        catch { #expect((error as? ChatGPTHelperError)?.code == "helper_stopped") }
        #expect(try await helper.request(ChatGPTHelperRequest(method: "state")).session?.status == "disconnected")
        await helper.shutdown()
    }

    @Test func processBridgeStreamsUnicodeAsOrderedCumulativeSnapshots() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let helper = ChatGPTHelper(helperDirectory: fixture.directory)
        let snapshots = SnapshotLog()
        let response = try await helper.request(ChatGPTHelperRequest(method: "stream"), onDelta: { snapshots.append($0) })
        #expect(response.text == "Aé")
        #expect(!snapshots.values.isEmpty)
        #expect(snapshots.values.allSatisfy { "Aé".hasPrefix($0) })
        await helper.shutdown()
    }

    @Test func cancellationCompletesWithoutWaitingForHelperAndNextRequestWorks() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let helper = ChatGPTHelper(helperDirectory: fixture.directory)
        let waiting = Task { try await helper.request(ChatGPTHelperRequest(method: "wait")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("Cancelled request reported success") }
        catch { #expect(error is CancellationError) }
        #expect(try await helper.request(ChatGPTHelperRequest(method: "state")).session?.status == "disconnected")
        await helper.shutdown()
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ChatGPTHelperError.timedOut
    }
}

private final class ForbiddenAPICredentials: CredentialStoring {
    var calls = 0
    func load(for endpoint: String) throws -> String? { calls += 1; throw CredentialStoreError.unreadableValue }
    func save(_ key: String, for endpoint: String) throws { calls += 1; throw CredentialStoreError.unreadableValue }
}

private actor FakePlanHelper: ChatGPTHelping {
    var requests: [ChatGPTHelperRequest] = []
    let sharing: Bool
    let holdReply: Bool
    let failReply: Bool
    var replyContinuation: CheckedContinuation<Void, Never>?
    init(sharing: Bool = true, holdReply: Bool = false, failReply: Bool = false) {
        self.sharing = sharing; self.holdReply = holdReply; self.failReply = failReply
    }
    func finishReply() { replyContinuation?.resume(); replyContinuation = nil }
    func request(_ request: ChatGPTHelperRequest, onDelta: (@Sendable (String) -> Void)?) async throws -> ChatGPTHelperResponse {
        requests.append(request)
        let json: String
        switch request.method {
        case "state": json = #"{"kind":"result","session":{"status":"connected","sharing":SHARING,"profileId":"profile"},"profiles":[]}"#.replacingOccurrences(of: "SHARING", with: String(sharing))
        case "models": json = #"{"kind":"result","models":[{"slug":"plan-model","displayName":"Plan model"}]}"#
        case "reply":
            onDelta?("Partial")
            if holdReply { await withCheckedContinuation { replyContinuation = $0 } }
            json = failReply ? #"{"kind":"result","error":{"code":"usage_limit","message":"Usage limit reached."}}"#
                : #"{"kind":"result","text":"Completed reply"}"#
        default: throw ChatGPTHelperError.interrupted
        }
        return try JSONDecoder().decode(ChatGPTHelperResponse.self, from: Data(json.utf8))
    }
    func shutdown() {}
}

private struct ProcessFixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launcher = directory.appendingPathComponent("node")
        try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("credential-vault"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let script = #"""
        import json, os, sys
        for line in sys.stdin:
            request = json.loads(line)
            method = request['method']
            if method == 'crash': os._exit(1)
            if method == 'malformed':
                print('not JSON', flush=True)
                continue
            if method in ('wait', 'cancel'): continue
            if method == 'stream':
                for delta in ['A', 'é']:
                    data = (json.dumps({'id': request['id'], 'kind': 'delta', 'delta': delta}, ensure_ascii=False) + '\n').encode('utf8')
                    os.write(1, data[:-3]); os.write(1, data[-3:])
                print(json.dumps({'id': request['id'], 'kind': 'result', 'text': 'Aé'}), flush=True)
                continue
            value = json.dumps({'id': request['id'], 'kind': 'result', 'session': {'status': 'disconnected', 'sharing': False}})
            sys.stdout.write(value[:12]); sys.stdout.flush()
            sys.stdout.write(value[12:] + '\n'); sys.stdout.flush()
        """#
        try script.write(to: directory.appendingPathComponent("helper.mjs"), atomically: true, encoding: .utf8)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String] = []
    func append(_ text: String) { lock.lock(); defer { lock.unlock() }; snapshots.append(text) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return snapshots }
}
