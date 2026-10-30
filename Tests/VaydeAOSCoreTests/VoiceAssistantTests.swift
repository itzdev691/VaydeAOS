import Foundation
import Testing
@testable import VaydeAOSCore

@MainActor
@Suite("Vayde voice lifecycle")
struct VoiceAssistantTests {
    @Test func standbyDoesNotStartDictationOrSendRequests() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        #expect(h.audio.wakeActive)
        #expect(h.audio.transcriptionStarts == 0)
        #expect(await h.client.prompts.isEmpty)
        #expect(h.audio.spoken.isEmpty)

        h.audio.wake?()
        #expect(h.voice.phase == .acknowledging)
        #expect(!h.audio.wakeActive)
        #expect(h.audio.transcriptionStarts == 0)
        #expect(h.audio.spoken == ["Yes?"])
        h.audio.completeSpeech()
        #expect(h.voice.phase == .listening)
        #expect(h.audio.transcriptionStarts == 1)
        #expect(await h.client.prompts.isEmpty)
    }

    @Test func voiceReplyPreservesDraftAndOnlySpeaksItsOwnAnswer() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        h.session.draft = "Unsent typed draft"
        try await h.start()
        h.activate()
        h.audio.update?("Explain this project", true)
        try await eventually { await h.client.prompts.count == 1 }
        #expect(h.voice.phase == .thinking)
        #expect(h.session.draft == "Unsent typed draft")
        h.session.draft = "Edited while Vayde thinks"
        h.session.saveDraft()
        let saved = try h.store.load(ChatLibrary.self, from: "chat-library.json")
        #expect(saved?.chats.first(where: { $0.id == h.session.selectedChatID })?.draft == "Edited while Vayde thinks")
        await h.client.succeed("The project is a command center.")
        try await eventually { h.voice.phase == .speaking }
        #expect(h.session.messages.map(\.content) == ["Explain this project", "The project is a command center."])
        #expect(h.session.draft == "Edited while Vayde thinks")
        #expect(h.audio.spoken == ["Yes?", "The project is a command center."])
        #expect(!h.audio.wakeActive && !h.audio.transcriptionActive)
        h.audio.completeSpeech()
        try await eventually { h.voice.phase == .waitingForWake }
        #expect(h.audio.wakeActive)
        #expect(h.audio.transcriptionStarts == 1)
    }

    @Test func failureDoesNotOverwriteTypedDraftOrSpeakOldHistory() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        h.activate()
        h.audio.update?("Voice prompt", true)
        try await eventually { await h.client.prompts.count == 1 }
        h.session.draft = "Keep my latest typing"
        await h.client.fail()
        try await eventually { h.voice.phase == .waitingForWake }
        #expect(h.session.draft == "Keep my latest typing")
        #expect(h.session.messages.isEmpty)
        #expect(h.session.interruptedTurns.last?.message.content == "Voice prompt")
        #expect(h.session.interruptedTurns.last?.originalDraft == "Voice prompt")
        #expect(h.voice.issue != nil)
        #expect(h.audio.spoken == ["Yes?"])
    }

    @Test func stopVoiceTurnCancelsOnlyItsRequestAndRejectsLateReply() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        h.session.draft = "Keep this draft"
        try await h.start()
        h.activate()
        h.audio.update?("Cancel this voice prompt", true)
        try await eventually { await h.client.prompts.count == 1 }
        h.voice.cancelInteraction()
        #expect(!h.session.isSending)
        #expect(h.session.draft == "Keep this draft")
        await h.client.succeed("Late cancelled answer")
        try await eventually { h.voice.phase == .waitingForWake }
        #expect(h.session.messages.isEmpty)
        #expect(h.audio.spoken == ["Yes?"])
    }

    @Test func typedRequestsPauseVoiceAndAreNotReadAloud() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        let staleWake = h.audio.wake
        h.session.draft = "Typed request"
        h.session.send()
        #expect(h.voice.phase == .busy)
        #expect(!h.audio.wakeActive)
        staleWake?()
        #expect(h.audio.transcriptionStarts == 0)
        try await eventually { await h.client.prompts.count == 1 }
        await h.client.succeed("Typed answer")
        try await eventually { h.voice.phase == .waitingForWake }
        #expect(h.audio.spoken.isEmpty)
    }

    @Test func chatStopRearmsVoiceBeforeAnUncooperativeClientReturns() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        h.activate()
        h.audio.update?("Stop from chat", true)
        try await eventually { await h.client.prompts.count == 1 }
        h.session.stop()
        try await eventually { h.voice.phase == .waitingForWake }
        await h.client.succeed("Late stopped answer")
        #expect(h.session.messages.isEmpty)
        #expect(h.audio.spoken == ["Yes?"])
    }

    @Test func disabledVoiceIgnoresLateWakeAndDictationCallbacks() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        let staleWake = h.audio.wake
        h.activate()
        let staleUpdate = h.audio.update
        h.voice.setEnabled(false)
        staleWake?()
        staleUpdate?("Do not send this", true)
        #expect(h.voice.phase == .off)
        #expect(!h.audio.wakeActive && !h.audio.transcriptionActive)
        #expect(await h.client.prompts.isEmpty)
        #expect(h.defaults.bool(forKey: "voice.alwaysListening") == false)
    }

    @Test func disablingDuringPermissionPromptCannotStartMicrophoneLater() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        h.audio.holdPreparation = true
        h.voice.start()
        try await eventually { h.audio.preparationContinuation != nil }
        h.voice.setEnabled(false)
        h.audio.preparationContinuation?.resume()
        h.audio.preparationContinuation = nil
        await Task.yield()
        #expect(h.voice.phase == .off)
        #expect(h.audio.wakeStarts == 0)
        #expect(h.audio.transcriptionStarts == 0)
    }

    @Test func changingChatDiscardsCapturedSpeech() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        h.activate()
        let staleUpdate = h.audio.update
        let previous = h.session.selectedChatID
        h.session.newChat()
        #expect(h.session.selectedChatID != previous)
        staleUpdate?("This belongs to the old chat", true)
        try await eventually { h.voice.phase == .waitingForWake }
        #expect(await h.client.prompts.isEmpty)
        #expect(!h.audio.transcriptionActive)
    }

    @Test func lockStopsAudioAndResumeRearmsWithoutAcceptingOldSpeech() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        h.activate()
        let staleUpdate = h.audio.update
        h.audio.onSuspensionChange?(true)
        #expect(h.voice.phase == .paused)
        #expect(!h.audio.wakeActive && !h.audio.transcriptionActive)
        staleUpdate?("Do not send after lock", true)
        h.audio.onSuspensionChange?(false)
        try await eventually { h.voice.phase == .waitingForWake }
        #expect(await h.client.prompts.isEmpty)
    }

    @Test func permissionFailureStaysStoppedUntilRetry() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        h.audio.prepareFails = true
        h.voice.start()
        try await eventually { h.voice.phase == .unavailable }
        #expect(h.voice.issue != nil)
        #expect(h.audio.wakeStarts == 0)
        #expect(h.audio.transcriptionStarts == 0)
        h.audio.prepareFails = false
        h.voice.retry()
        try await eventually { h.voice.phase == .waitingForWake }
        #expect(h.voice.issue == nil)
    }

    @Test func turningOffDuringInferenceSuppressesPlaybackButPreservesTheTurn() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        h.activate()
        h.audio.update?("Finish silently", true)
        try await eventually { await h.client.prompts.count == 1 }
        h.voice.setEnabled(false)
        await h.client.succeed("Saved silently")
        try await eventually { !h.session.isSending }
        #expect(h.voice.phase == .off)
        #expect(h.session.messages.last?.content == "Saved silently")
        #expect(h.audio.spoken == ["Yes?"])
    }

    @Test func settingsBlockWakeUntilClosed() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        h.voice.setInteractionBlocked(true)
        #expect(h.voice.phase == .busy)
        #expect(!h.audio.wakeActive)
        h.voice.setInteractionBlocked(false)
        try await eventually { h.voice.phase == .waitingForWake }
    }

    @Test func emptyCaptureNeverSendsAndReturnsToStandby() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        h.activate()
        h.audio.update?("  ", true)
        try await eventually { h.voice.phase == .waitingForWake }
        #expect(await h.client.prompts.isEmpty)
    }

    @Test func pauseAfterSpeechSubmitsOnceWithoutWaitingForFinalResult() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        h.activate()
        let staleUpdate = h.audio.update
        h.audio.update?("Send this after a pause", false)
        try await eventually { await h.client.prompts.count == 1 }
        #expect(!h.audio.transcriptionActive)
        staleUpdate?("Late revised text", true)
        #expect(await h.client.prompts == ["Send this after a pause"])
        await h.client.succeed("Done")
        try await eventually { h.voice.phase == .speaking }
    }

    @Test func silentActivationTimesOutAndRearmsWithoutSending() async throws {
        let h = VoiceHarness()
        defer { h.shutdown() }
        try await h.start()
        h.activate()
        try await eventually { h.voice.phase == .waitingForWake }
        #expect(!h.audio.transcriptionActive)
        #expect(await h.client.prompts.isEmpty)
    }

    @Test func speechTextOmitsCodeAndMarkdownSyntax() {
        let text = VoiceSpeechText.readable("**Result**: [Apple](https://apple.com).\n```swift\nprint(42)\n```")
        #expect(text.contains("Result: Apple."))
        #expect(text.contains("Code is shown in the chat."))
        #expect(!text.contains("print(42)"))
        #expect(!text.contains("https://"))
        #expect(VoiceSpeechText.readable(String(repeating: "a", count: 4_000)).hasSuffix("The rest of the response is in the chat."))
    }
}

@MainActor
private func eventually(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await predicate()) {
        if ContinuousClock.now >= deadline { throw VoiceTestError.timedOut }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor
private final class VoiceHarness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "VaydeVoiceTests.\(UUID().uuidString)"
    let store: LocalStore
    let defaults: UserDefaults
    let client = VoiceTestClient()
    let audio = TestVoiceAudio()
    let session: ChatSession
    let voice: VoiceAssistant

    init() {
        store = LocalStore(directory: directory)
        defaults = UserDefaults(suiteName: suite)!
        session = ChatSession(client: client, store: store, credentials: VoiceTestCredentials())
        voice = VoiceAssistant(session: session, audio: audio, defaults: defaults)
    }

    func start() async throws {
        voice.start()
        try await eventually { self.voice.phase == .waitingForWake }
    }

    func activate() {
        audio.wake?()
        audio.completeSpeech()
    }

    func shutdown() {
        voice.shutdown()
        session.stop()
        session.codex.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class TestVoiceAudio: VoiceAudioServing {
    var onSuspensionChange: ((Bool) -> Void)?
    var wake: (() -> Void)?
    var update: ((String, Bool) -> Void)?
    var failure: ((String) -> Void)?
    var speechCompletion: (() -> Void)?
    var wakeActive = false
    var transcriptionActive = false
    var wakeStarts = 0
    var transcriptionStarts = 0
    var spoken: [String] = []
    var holdPreparation = false
    var prepareFails = false
    var preparationContinuation: CheckedContinuation<Void, Never>?

    func prepare() async throws {
        if holdPreparation {
            await withCheckedContinuation { preparationContinuation = $0 }
        }
        if prepareFails { throw VoiceTestError.denied }
    }

    func startWakeListening(onWake: @escaping () -> Void) throws {
        wake = onWake; wakeActive = true; wakeStarts += 1
    }
    func stopWakeListening() { wake = nil; wakeActive = false }
    func startTranscription(onUpdate: @escaping (String, Bool) -> Void,
                            onFailure: @escaping (String) -> Void) throws {
        update = onUpdate; failure = onFailure; transcriptionActive = true; transcriptionStarts += 1
    }
    func stopTranscription() { update = nil; failure = nil; transcriptionActive = false }
    func speak(_ text: String, onFinished: @escaping () -> Void) {
        spoken.append(text); speechCompletion = onFinished
    }
    func stopSpeaking() { speechCompletion = nil }
    func completeSpeech() {
        let completion = speechCompletion
        speechCompletion = nil
        completion?()
    }
}

private actor VoiceTestClient: ChatServing {
    private(set) var prompts: [String] = []
    private var continuation: CheckedContinuation<String, Error>?
    func reply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> String {
        prompts.append(messages.last!.content)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func succeed(_ text: String) { continuation?.resume(returning: text); continuation = nil }
    func fail() { continuation?.resume(throwing: VoiceTestError.denied); continuation = nil }
}

private final class VoiceTestCredentials: CredentialStoring {
    func load(for endpoint: String) throws -> String? { nil }
    func save(_ key: String, for endpoint: String) throws { }
}

private enum VoiceTestError: Error { case denied, timedOut }
