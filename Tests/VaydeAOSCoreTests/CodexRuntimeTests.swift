import Foundation
import Testing
@testable import VaydeAOSCore

@MainActor
@Suite("Embedded Codex runtime")
final class CodexRuntimeTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaydeAOS-Codex-" + UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func oldSettingsDecodeAndCodexDoesNotRequireAnAPIEndpoint() throws {
        let old = Data(#"{"baseURL":"http://localhost:11434/v1","model":"local"}"#.utf8)
        let decoded = try JSONDecoder().decode(ConnectionSettings.self, from: old)
        #expect(decoded.provider == .compatibleAPI)
        #expect(!decoded.codexAllowsWrites)
        let settings = configuration()
        #expect(try settings.validated().codexWorkspace == directory.resolvingSymlinksInPath().path)
        #expect(settings.activeModel == "ChatGPT default")
        var missing = settings; missing.codexWorkspace = directory.appendingPathComponent("missing").path
        #expect(throws: ConnectionSettingsError.self) { try missing.validated() }
    }

    @Test func streamsThenSavesOnlyFinalAnswerAndResumesAfterRelaunch() async throws {
        let runtime = try makeRuntime()
        var partials: [String] = []
        let user = ChatMessage(role: .user, content: "First")
        let result = try await runtime.reply(to: [user], settings: configuration()) { partials.append($0) }
        #expect(result.content == "Final café")
        #expect(partials.contains(where: { $0.contains("Working") }))
        #expect(partials.last?.contains("café") == true)
        #expect(runtime.threadID == "thread-1")
        #expect(runtime.activity.last?.status == "completed")
        runtime.shutdown()

        let relaunched = try makeRuntime()
        let history = [user, ChatMessage(role: .assistant, content: result.content), ChatMessage(role: .user, content: "Follow-up")]
        _ = try await relaunched.reply(to: history, settings: configuration()) { _ in }
        relaunched.shutdown()
        let log = try requests()
        #expect(log.filter { $0["method"].text == "thread/start" }.count == 1)
        #expect(log.filter { $0["method"].text == "thread/resume" }.count == 1)
        let starts = log.filter { $0["method"].text == "turn/start" }
        #expect(starts.map { $0["params"]["input"].values.first?["text"].text } == ["First", "Follow-up"])
        let policy = try #require(log.first { $0["method"].text == "thread/start" })["params"]
        #expect(policy["sandbox"].text == "read-only")
        #expect(policy["approvalPolicy"].text == "untrusted")
        #expect(policy["approvalsReviewer"].text == "user")
        let audit = try String(contentsOf: directory.appendingPathComponent("codex-session.json"), encoding: .utf8)
        #expect(!audit.contains("private command output"))
    }

    @Test func approvalsRequireExplicitResponseAndRejectStaleRequests() async throws {
        let runtime = try makeRuntime(mode: "approval")
        let task = Task { try await runtime.reply(to: [ChatMessage(role: .user, content: "Work")], settings: configuration()) { _ in } }
        try await wait { !runtime.prompts.isEmpty }
        let prompt = try #require(runtime.prompts.first)
        #expect(prompt.detail.contains("touch sample.txt"))
        #expect(runtime.activity.first?.status == "inProgress")
        #expect(!(try requests()).contains { $0["id"].text == "approve-1" && $0["result"] != .null })
        runtime.answer(prompt, approve: true)
        let result = try await task.value
        #expect(result.content == "Final café")
        #expect(runtime.prompts.isEmpty)
        let log = try requests()
        #expect(log.contains { $0["id"].text == "stale" && $0["error"] != .null })
        #expect(log.contains { $0["id"].text == "approve-1" && $0["result"]["decision"].text == "accept" })
        runtime.shutdown()
    }

    @Test func inputAndUnknownServerRequestsDoNotAutomaticallyGrantAccess() async throws {
        let runtime = try makeRuntime(mode: "input")
        let task = Task { try await runtime.reply(to: [ChatMessage(role: .user, content: "Work")], settings: configuration()) { _ in } }
        try await wait { !runtime.prompts.isEmpty }
        let prompt = try #require(runtime.prompts.first)
        #expect(prompt.questions.first?.options == ["Accept", "Decline"])
        runtime.answer(prompt, answers: ["choice": "Decline"])
        _ = try await task.value
        let log = try requests()
        #expect(log.contains { $0["id"].text == "unsupported" && $0["error"] != .null })
        #expect(log.contains { $0["id"].text == "input-1" && $0["result"]["answers"]["choice"]["answers"].values == [.string("Decline")] })
        runtime.shutdown()
    }

    @Test(arguments: ["failed", "crash", "malformed"])
    func failureNeverCommitsAPartialAnswer(mode: String) async throws {
        let runtime = try makeRuntime(mode: mode)
        let session = ChatSession(store: LocalStore(directory: directory), codex: runtime)
        try session.saveSettings(configuration(), apiKey: "")
        session.draft = "Keep this prompt"
        session.send()
        let task = try #require(session.sendTask)
        await task.value
        #expect(session.messages.isEmpty)
        #expect(session.draft == "Keep this prompt")
        #expect(session.errorMessage != nil)
        #expect(session.performanceHistory.last?.outcome == .failed)
        let record = try #require(try LocalStore(directory: directory).load(CodexRecord.self, from: "codex-session.json"))
        #expect(record.interrupted)
        runtime.shutdown()
    }

    @Test(arguments: ["hold", "pendingAck"])
    func stopCancelsEvenBeforeTurnAcknowledgementAndNewChatStartsFresh(mode: String) async throws {
        let runtime = try makeRuntime(mode: mode)
        let session = ChatSession(store: LocalStore(directory: directory), codex: runtime)
        try session.saveSettings(configuration(), apiKey: "")
        session.draft = "Cancel this"
        session.send()
        let task = try #require(session.sendTask)
        try await wait { (try? self.requests().contains { $0["method"].text == "turn/start" }) == true }
        session.stop()
        await task.value
        #expect(!session.isSending)
        #expect(!runtime.isRunning)
        #expect(runtime.prompts.isEmpty)
        #expect(session.messages.isEmpty)
        #expect(session.notice?.contains("not undone") == true)
        #expect(session.draft == "Cancel this")
        session.newChat()
        #expect(runtime.threadID == nil)
        #expect(runtime.activity.isEmpty)
    }

    @Test func corruptHistoryIsPreservedUntilNewChat() async throws {
        let url = directory.appendingPathComponent("codex-session.json")
        try Data("corrupt".utf8).write(to: url)
        let runtime = try makeRuntime()
        do {
            _ = try await runtime.reply(to: [ChatMessage(role: .user, content: "Work")], settings: configuration()) { _ in }
            Issue.record("Expected corrupt-history rejection")
        } catch { }
        runtime.shutdown()
        #expect(try String(contentsOf: url, encoding: .utf8) == "corrupt")
        runtime.newChat()
        _ = try await runtime.reply(to: [ChatMessage(role: .user, content: "Work")], settings: configuration()) { _ in }
        runtime.shutdown()
    }

    @Test func changedWorkspaceDoesNotReuseOldThread() async throws {
        let runtime = try makeRuntime()
        let user = ChatMessage(role: .user, content: "First")
        let result = try await runtime.reply(to: [user], settings: configuration()) { _ in }
        let other = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var settings = configuration(); settings.codexWorkspace = other.path
        _ = try await runtime.reply(to: [user, ChatMessage(role: .assistant, content: result.content), ChatMessage(role: .user, content: "Next")], settings: settings) { _ in }
        #expect(try requests().filter { $0["method"].text == "thread/start" }.count == 2)
        runtime.shutdown()
    }

    @Test func discoveryDoesNotConfuseNoOAuthWithUnsupportedTools() async throws {
        let runtime = try makeRuntime()
        await runtime.refresh(settings: configuration())
        let server = try #require(runtime.integrations.first { $0.name == "filesystem" })
        #expect(server.state == "tools available")
        #expect(server.toolCount == 1)
        runtime.shutdown()
    }

    @Test func savedProvidersMergeWithoutLosingModelOrConversation() throws {
        #expect(ConnectionSettings.Provider.allCases == [.compatibleAPI, .chatGPT])
        let oldRuntime = Data(#"{"baseURL":"http://localhost:11434/v1","model":"local","provider":"codex","chatGPTModel":"stale-helper-model","codexModel":"runtime-model","codexWorkspace":"/tmp","codexAllowsWrites":true}"#.utf8)
        let runtime = try JSONDecoder().decode(ConnectionSettings.self, from: oldRuntime).validated()
        #expect(runtime.provider == .chatGPT)
        #expect(runtime.activeModel == "runtime-model")
        #expect(runtime.codexAllowsWrites)
        let oldHelper = Data(#"{"baseURL":"http://localhost:11434/v1","model":"local","provider":"chatGPT","chatGPTModel":"helper-model","codexModel":"stale-runtime-model","codexAllowsWrites":true}"#.utf8)
        let helper = try JSONDecoder().decode(ConnectionSettings.self, from: oldHelper).validated()
        #expect(helper.activeModel == "helper-model")
        #expect(!helper.codexAllowsWrites)
        #expect(helper.needsChatGPTAccountReview)
        let store = LocalStore(directory: directory)
        let history = [ChatMessage(role: .user, content: "Existing conversation")]
        try store.saveMessages(history)
        try store.saveSettings(runtime)
        let restored = ChatSession(store: store)
        #expect(restored.settings.provider == .chatGPT)
        #expect(restored.messages == history)
        #expect(restored.settings.codexAllowsWrites)
        let saved = try String(contentsOf: directory.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(!saved.contains("\"provider\" : \"codex\""))
    }

    @Test func unifiedChatGPTNeverUsesAPIKeychainAndKeepsCompletedHistory() async throws {
        let runtime = try makeRuntime()
        let credentials = NoAPICredentials()
        let store = LocalStore(directory: directory)
        let session = ChatSession(store: store, credentials: credentials, codex: runtime)
        var settings = configuration(); settings.provider = .chatGPT
        settings.chatGPTModel = "fixture-model"
        try session.saveSettings(settings, apiKey: "ignored")
        try session.setReasoningEffort(.high)
        #expect(try session.apiKey(for: settings) == nil)
        session.draft = "First prompt"; session.send(); await session.sendTask?.value
        session.draft = "Follow-up"; session.send(); await session.sendTask?.value
        #expect(session.messages.map(\.content) == ["First prompt", "Final café", "Follow-up", "Final café"])
        #expect(try store.loadMessages() == session.messages)
        #expect(session.partialReply.isEmpty)
        #expect(credentials.calls == 0)
        let turns = try requests().filter { $0["method"].text == "turn/start" }
        #expect(turns.count == 2)
        #expect(turns.allSatisfy { $0["params"]["effort"].text == "high" })
        #expect(session.performanceHistory.map(\.outcome) == [.success, .success])
        runtime.shutdown()
    }

    @Test func legacyHelperAccountMustBeConfirmedBeforeSendingAndCredentialsStayUntouched() async throws {
        let store = LocalStore(directory: directory)
        let old = Data(#"{"baseURL":"http://localhost:11434/v1","model":"local","provider":"chatGPT","chatGPTModel":"legacy-model"}"#.utf8)
        try old.write(to: directory.appendingPathComponent("settings.json"))
        let legacyDirectory = directory.appendingPathComponent("ChatGPT")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyFile = legacyDirectory.appendingPathComponent("credentials.json")
        let preserved = Data("opaque-legacy-envelope".utf8)
        try preserved.write(to: legacyFile)
        let runtime = try makeRuntime()
        let session = ChatSession(store: store, credentials: NoAPICredentials(), codex: runtime)
        session.draft = "Existing conversation"
        #expect(!session.canSend)
        #expect(throws: CodexRuntimeError.self) { try session.saveSettings(session.settings, apiKey: "") }
        await runtime.refresh(settings: session.settings)
        #expect(!session.canSend)
        try session.saveSettings(session.settings, apiKey: "")
        #expect(!session.settings.needsChatGPTAccountReview)
        #expect(session.canSend)
        session.send(); await session.sendTask?.value
        #expect(session.messages.last?.content == "Final café")
        #expect(try Data(contentsOf: legacyFile) == preserved)
        #expect(try store.loadSettings()?.needsChatGPTAccountReview == false)
        runtime.shutdown()
    }

    @Test func noSelectedFolderUsesPrivateReadOnlyWorkspace() async throws {
        let runtime = try makeRuntime()
        let settings = ConnectionSettings(baseURL: "", model: "", provider: .chatGPT)
        _ = try await runtime.reply(to: [ChatMessage(role: .user, content: "Chat")], settings: settings) { _ in }
        let start = try #require(try requests().first { $0["method"].text == "thread/start" })
        #expect(start["params"]["cwd"].text == directory.appendingPathComponent("Workspace").resolvingSymlinksInPath().path)
        #expect(start["params"]["sandbox"].text == "read-only")
        #expect(start["params"]["modelProvider"].text == "openai")
        #expect(start["params"]["model"].text == "fixture-model")
        runtime.shutdown()
    }

    @Test func missingChatGPTAccountBlocksTurnWithoutFallingBackToAPIKey() async throws {
        let runtime = try makeRuntime(mode: "signedOut")
        do {
            _ = try await runtime.reply(to: [ChatMessage(role: .user, content: "Chat")], settings: configuration()) { _ in }
            Issue.record("Expected account rejection")
        } catch { #expect(error as? CodexRuntimeError != nil) }
        #expect(!runtime.isSignedIn)
        #expect(try requests().allSatisfy { $0["method"].text != "turn/start" })
        runtime.shutdown()
    }

    @Test func bundledRuntimeSmokeWhenExplicitlyEnabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["VAYDEAOS_CODEX_SMOKE"] else { return }
        let runtime = CodexRuntime(process: CodexProcess(executable: URL(fileURLWithPath: path)), store: LocalStore(directory: directory))
        await runtime.refresh(settings: configuration())
        #expect(runtime.isConnected)
        #expect(!runtime.models.isEmpty)
        print("Codex smoke: connected=\(runtime.isConnected), models=\(runtime.models.count), integrations=\(runtime.integrations.count)")
        if ProcessInfo.processInfo.environment["VAYDEAOS_CODEX_LIVE"] == "1" {
            try Data("VAYDEAOS_RUNTIME_PROOF_42\n".utf8).write(to: directory.appendingPathComponent("proof.txt"))
            var settings = configuration()
            settings.codexModel = try #require(runtime.models.first).id
            let run = Task {
                try await runtime.reply(to: [ChatMessage(role: .user, content: "Read proof.txt using exactly the shell command: cat proof.txt . Return only its exact contents. Do not modify files, access other services, or delegate.")], settings: settings) { _ in }
            }
            try await waitForLiveTurn(runtime: runtime)
            let reply = try await run.value
            #expect(reply.content.trimmingCharacters(in: .whitespacesAndNewlines) == "VAYDEAOS_RUNTIME_PROOF_42")
            #expect(runtime.activity.contains { $0.status == "completed" })
            print("Codex live proof: file read and final marker verified; \(runtime.activity.count) tool events")
        }
        runtime.shutdown()
    }

    private func configuration() -> ConnectionSettings {
        ConnectionSettings(baseURL: "", model: "", provider: .codex, codexWorkspace: directory.path)
    }
    private func waitForLiveTurn(runtime: CodexRuntime) async throws {
        let deadline = Date().addingTimeInterval(120)
        var started = false
        while Date() < deadline {
            if runtime.isRunning { started = true }
            if started && !runtime.isRunning { return }
            for prompt in runtime.prompts {
                // This test authorizes only the requested temporary-file read, never a general approval.
                let safeCommands = ["cat proof.txt", "/bin/cat proof.txt", "/bin/zsh -lc 'cat proof.txt'", "/bin/bash -lc 'cat proof.txt'"]
                let command = prompt.detail.components(separatedBy: "\n\n").first ?? ""
                if prompt.questions.isEmpty && safeCommands.contains(command) {
                    runtime.answer(prompt, approve: true)
                } else {
                    print("Codex live smoke refused unexpected prompt: \(prompt.title), command: \(command)")
                    runtime.cancel()
                    throw CodexRuntimeError.requestFailed("unexpected smoke-test approval")
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        runtime.cancel()
        throw CodexRuntimeError.timedOut
    }
    private func makeRuntime(mode: String = "stream") throws -> CodexRuntime {
        let fixture = directory.appendingPathComponent("codex-fixture.py")
        try Self.fixture.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let process = CodexProcess(executable: fixture, environment: ["PATH": "/usr/bin:/bin", "FIXTURE_MODE": mode, "FIXTURE_LOG": directory.appendingPathComponent("rpc.jsonl").path])
        return CodexRuntime(process: process, store: LocalStore(directory: directory))
    }
    private func requests() throws -> [CodexValue] {
        let text = try String(contentsOf: directory.appendingPathComponent("rpc.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(CodexValue.self, from: Data($0.utf8)) }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw CodexRuntimeError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private static let fixture = #"""
#!/usr/bin/python3
import json,os,sys
mode=os.environ['FIXTURE_MODE']
turn=0
thread='thread-1'
def out(d):
 data=(json.dumps(d,ensure_ascii=False)+'\n').encode()
 # Exercise fragmented UTF-8 and JSON protocol frames.
 for i in range(0,len(data),7):os.write(1,data[i:i+7])
def event(method,params):out({'method':method,'params':dict({'threadId':thread,'turnId':'turn-'+str(turn)},**params)})
def complete():
 event('item/started',{'item':{'id':'tool-'+str(turn),'type':'commandExecution','command':'cat proof.txt','status':'inProgress'}})
 event('item/completed',{'item':{'id':'tool-'+str(turn),'type':'commandExecution','command':'cat proof.txt','aggregatedOutput':'private command output','status':'completed'}})
 event('item/agentMessage/delta',{'itemId':'comment-'+str(turn),'delta':'Working'})
 event('item/completed',{'item':{'id':'comment-'+str(turn),'type':'agentMessage','phase':'commentary','text':'Working'}})
 event('item/agentMessage/delta',{'itemId':'answer-'+str(turn),'delta':'Final café'})
 event('item/completed',{'item':{'id':'answer-'+str(turn),'type':'agentMessage','phase':'final_answer','text':'Final café'}})
 event('turn/completed',{'turn':{'id':'turn-'+str(turn),'status':'completed'}})
for line in sys.stdin:
 d=json.loads(line)
 with open(os.environ['FIXTURE_LOG'],'a') as f:f.write(json.dumps(d)+'\n')
 method=d.get('method');rid=d.get('id');params=d.get('params',{})
 if not method:
  if rid in ['approve-1','input-1']:complete()
  continue
 if method=='initialize':out({'id':rid,'result':{'userAgent':'fixture'}})
 elif method=='initialized':pass
 elif method=='thread/start' or method=='thread/resume':
  out({'id':rid,'result':{'thread':{'id':thread}}})
 elif method=='turn/start':
  turn+=1
  if mode=='pendingAck':continue
  out({'id':rid,'result':{'turn':{'id':'turn-'+str(turn)}}})
  event('turn/started',{'turn':{'id':'turn-'+str(turn),'status':'inProgress'}})
  if mode=='hold':continue
  if mode=='crash':sys.exit(3)
  if mode=='malformed':os.write(1,b'bad-json\n');continue
  if mode=='failed':
   event('item/agentMessage/delta',{'itemId':'partial','delta':'Do not save'})
   event('turn/completed',{'turn':{'id':'turn-'+str(turn),'status':'failed'}})
  elif mode=='approval':
   event('item/started',{'item':{'id':'approval-tool','type':'commandExecution','command':'touch sample.txt','status':'inProgress'}})
   out({'id':'stale','method':'item/commandExecution/requestApproval','params':{'threadId':'different-thread','turnId':'old'}})
   out({'id':'approve-1','method':'item/commandExecution/requestApproval','params':{'threadId':thread,'turnId':'turn-'+str(turn),'itemId':'approval-tool','command':'touch sample.txt','cwd':params.get('cwd','/tmp')}})
  elif mode=='input':
   out({'id':'unsupported','method':'unknown/permission','params':{'threadId':thread}})
   out({'id':'input-1','method':'tool/requestUserInput','params':{'threadId':thread,'turnId':'turn-'+str(turn),'questions':[{'id':'choice','question':'Approve service action?','options':[{'label':'Accept'},{'label':'Decline'}]}]}})
  else:complete()
 elif method=='turn/interrupt':out({'id':rid,'result':{}})
 elif method=='account/read':out({'id':rid,'result':{'account':None if mode=='signedOut' else {'type':'chatgpt','email':'fixture@example.test','planType':'plus'}}})
 elif method=='model/list':out({'id':rid,'result':{'data':[{'id':'fixture-model','model':'fixture-model','displayName':'Fixture model','isDefault':True}]}})
 elif method=='mcpServerStatus/list':out({'id':rid,'result':{'data':[{'name':'filesystem','authStatus':'unsupported','tools':{'read_file':{'name':'read_file'}}}]}})
 else:out({'id':rid,'result':{}})
"""#
}

private final class NoAPICredentials: CredentialStoring {
    private(set) var calls = 0
    func load(for endpoint: String) throws -> String? { calls += 1; throw CodexRuntimeError.invalidProtocol }
    func save(_ key: String, for endpoint: String) throws { calls += 1; throw CodexRuntimeError.invalidProtocol }
}
