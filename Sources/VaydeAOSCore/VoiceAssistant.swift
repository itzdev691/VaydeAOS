import Combine
import Foundation

/// The idle command matcher and active dictation are separate so standby never runs dictation.
@MainActor
public protocol VoiceAudioServing: AnyObject {
    var onSuspensionChange: ((Bool) -> Void)? { get set }
    func prepare() async throws
    func startWakeListening(onWake: @escaping () -> Void) throws
    func stopWakeListening()
    func startTranscription(onUpdate: @escaping (String, Bool) -> Void,
                            onFailure: @escaping (String) -> Void) throws
    func stopTranscription()
    func speak(_ text: String, onFinished: @escaping () -> Void)
    func stopSpeaking()
}

@MainActor
public final class VoiceAssistant: ObservableObject {
    public enum Phase: Equatable {
        case off, preparing, waitingForWake, acknowledging, listening, thinking, speaking, busy, paused, unavailable
    }

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var phase: Phase = .off
    @Published public private(set) var transcript = ""
    @Published public private(set) var issue: String?
    public var onActivation: (() -> Void)?

    private let audio: any VoiceAudioServing
    private let session: ChatSession
    private let defaults: UserDefaults
    private var subscriptions: Set<AnyCancellable> = []
    private var preparation: Task<Void, Never>?
    private var turn: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var rearm: Task<Void, Never>?
    private var generation = UUID()
    private var activeChatID: UUID?
    private var started = false
    private var suspended = false
    private var hasAccess = false
    private var interactionBlocked = false

    public init(session: ChatSession, audio: any VoiceAudioServing, defaults: UserDefaults = .standard) {
        self.session = session
        self.audio = audio
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "voice.alwaysListening") as? Bool ?? true
        audio.onSuspensionChange = { [weak self] in self?.setSuspended($0) }
        session.$isSending.dropFirst().sink { [weak self] sending in
            guard let self else { return }
            if sending, [.acknowledging, .listening, .waitingForWake].contains(self.phase) {
                self.invalidateAudio()
                self.phase = .busy
            } else if !sending, self.phase == .busy {
                // Published properties emit before the session's stored value changes.
                self.scheduleWake()
            }
        }.store(in: &subscriptions)
        session.$selectedChatID.dropFirst().sink { [weak self] _ in
            guard let self, self.activeChatID != nil else { return }
            self.invalidateAudio()
            self.scheduleWake()
        }.store(in: &subscriptions)
    }

    public var statusText: String {
        switch phase {
        case .off: return "Voice off"
        case .preparing: return "Preparing voice access"
        case .waitingForWake: return "Listening for “Hey Vayde”"
        case .acknowledging: return "Vayde is ready"
        case .listening: return "Listening to your request"
        case .thinking: return "Vayde is responding"
        case .speaking: return "Speaking"
        case .busy: return "Voice paused while the chat is busy"
        case .paused: return "Voice paused while Mac is locked or asleep"
        case .unavailable: return "Voice needs attention"
        }
    }

    public var isInteracting: Bool { [.acknowledging, .listening, .thinking, .speaking].contains(phase) }

    public func start() {
        guard !started else { return }
        started = true
        if isEnabled { prepare() }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "voice.alwaysListening")
        invalidateAudio()
        issue = nil
        if enabled, started { prepare() } else { phase = .off }
    }

    public func retry() {
        guard isEnabled, started else { return }
        invalidateAudio()
        prepare()
    }

    public func listenNow() {
        guard phase == .waitingForWake else { return }
        wake()
    }

    public func cancelInteraction() {
        let cancelRequest = phase == .thinking && activeChatID == session.selectedChatID
        invalidateAudio()
        if cancelRequest { session.stop() }
        scheduleWake()
    }

    public func setSuspended(_ value: Bool) {
        suspended = value
        invalidateAudio()
        guard isEnabled, started else { phase = .off; return }
        if value { phase = .paused } else { prepare() }
    }

    public func setInteractionBlocked(_ value: Bool) {
        interactionBlocked = value
        guard started, isEnabled, !suspended, phase != .unavailable else { return }
        if value {
            invalidateAudio()
            phase = .busy
        } else { scheduleWake() }
    }

    public func shutdown() {
        started = false
        invalidateAudio()
        phase = .off
    }

    private func prepare() {
        guard isEnabled, started, !suspended else { phase = suspended ? .paused : .off; return }
        phase = .preparing
        issue = nil
        let token = generation
        preparation = Task { [weak self, audio] in
            do {
                try await audio.prepare()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.hasAccess = true
                self.armWake()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func armWake() {
        guard started, isEnabled, !suspended, hasAccess else { return }
        guard !session.isSending, !interactionBlocked else { phase = .busy; return }
        let token = generation
        do {
            try audio.startWakeListening { [weak self] in
                guard let self, self.generation == token else { return }
                self.wake()
            }
            phase = .waitingForWake
        } catch { fail(error.localizedDescription) }
    }

    private func wake() {
        guard phase == .waitingForWake, isEnabled, !suspended else { return }
        guard session.canSendVoice else {
            issue = "The current chat cannot send. Check its connection and model settings."
            onActivation?()
            return
        }
        audio.stopWakeListening()
        transcript = ""
        issue = nil
        activeChatID = session.selectedChatID
        phase = .acknowledging
        let token = generation
        onActivation?()
        audio.speak("Yes?") { [weak self] in
            guard let self, self.generation == token, self.phase == .acknowledging else { return }
            self.beginListening()
        }
    }

    private func beginListening() {
        phase = .listening
        let token = generation
        do {
            try audio.startTranscription(onUpdate: { [weak self] text, final in
                guard let self, self.generation == token, self.phase == .listening else { return }
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let changed = text != self.transcript
                self.transcript = text
                if final { self.finishListening() }
                else if changed, !text.isEmpty { self.scheduleSilence(token) }
            }, onFailure: { [weak self] message in
                guard let self, self.generation == token, self.phase == .listening else { return }
                self.fail(message)
            })
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                guard let self, self.generation == token, self.phase == .listening else { return }
                if self.transcript.isEmpty { self.finishListening(); return }
                do { try await Task.sleep(nanoseconds: 22_000_000_000) } catch { return }
                guard self.generation == token else { return }
                self.finishListening()
            }
        } catch { fail(error.localizedDescription) }
    }

    private func scheduleSilence(_ token: UUID) {
        silence?.cancel()
        silence = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.finishListening()
        }
    }

    public func finishListening() {
        guard phase == .listening else { return }
        audio.stopTranscription()
        deadline?.cancel()
        silence?.cancel()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeChatID == session.selectedChatID else { scheduleWake(); return }
        guard session.canSendVoice else {
            issue = "The chat became unavailable. The voice request was not sent."
            scheduleWake()
            return
        }
        phase = .thinking
        let token = generation
        turn = Task { [weak self, session] in
            let reply = await session.sendVoice(text)
            guard let self, !Task.isCancelled, self.generation == token,
                  self.isEnabled, !self.suspended else { return }
            guard let reply else {
                self.issue = session.errorMessage ?? "Voice request stopped."
                self.scheduleWake()
                return
            }
            self.phase = .speaking
            // The command matcher and microphone remain stopped throughout playback.
            self.audio.speak(reply) { [weak self] in
                guard let self, self.generation == token, self.phase == .speaking else { return }
                self.scheduleWake()
            }
        }
    }

    private func scheduleWake() {
        invalidateAudio()
        guard isEnabled, started else { phase = .off; return }
        guard !suspended else { phase = .paused; return }
        // Let speaker output settle before rearming to avoid hearing Vayde's own answer.
        phase = .preparing
        let token = generation
        rearm = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            if self.hasAccess { self.armWake() } else { self.prepare() }
        }
    }

    private func fail(_ message: String) {
        invalidateAudio()
        issue = message
        phase = .unavailable
    }

    private func invalidateAudio() {
        generation = UUID()
        preparation?.cancel(); preparation = nil
        turn?.cancel(); turn = nil
        deadline?.cancel(); deadline = nil
        silence?.cancel(); silence = nil
        rearm?.cancel(); rearm = nil
        activeChatID = nil
        audio.stopWakeListening()
        audio.stopTranscription()
        audio.stopSpeaking()
    }
}
