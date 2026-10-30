import AppKit
import AVFoundation
import Speech
import VaydeAOSCore

/// macOS matches a small command grammar in standby. Full dictation starts only after activation.
@MainActor
final class MacVoiceAudio: NSObject, VoiceAudioServing, NSSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate {
    var onSuspensionChange: ((Bool) -> Void)?
    private var wakeRecognizer: NSSpeechRecognizer?
    private var wakeHandler: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var speechFinished: (() -> Void)?
    private var spokenUtterance: AVSpeechUtterance?
    private var engine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionID = UUID()
    private var configurationObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var suspensions: Set<String> = []

    override init() {
        super.init()
        synthesizer.delegate = self
        observeWorkspace(NSWorkspace.willSleepNotification, reason: "sleep", suspended: true)
        observeWorkspace(NSWorkspace.didWakeNotification, reason: "sleep", suspended: false)
        observeWorkspace(NSWorkspace.sessionDidResignActiveNotification, reason: "session", suspended: true)
        observeWorkspace(NSWorkspace.sessionDidBecomeActiveNotification, reason: "session", suspended: false)
        observeLock("com.apple.screenIsLocked", suspended: true)
        observeLock("com.apple.screenIsUnlocked", suspended: false)
    }

    deinit {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func prepare() async throws {
        let microphoneAllowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneAllowed = true
        case .notDetermined: microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: microphoneAllowed = false
        }
        try Task.checkCancellation()
        guard microphoneAllowed else {
            throw VoiceError("Microphone access is off. Enable VaydeAOS in System Settings → Privacy & Security → Microphone, then retry.")
        }
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else { speechStatus = SFSpeechRecognizer.authorizationStatus() }
        try Task.checkCancellation()
        guard speechStatus == .authorized else {
            throw VoiceError("Speech recognition access is off. Enable VaydeAOS in System Settings → Privacy & Security → Speech Recognition, then retry.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else {
            throw VoiceError("On-device English speech recognition is unavailable on this Mac. Voice stays off; audio will not fall back to a server.")
        }
        self.recognizer = recognizer
    }

    func startWakeListening(onWake: @escaping () -> Void) throws {
        stopWakeListening()
        guard let matcher = NSSpeechRecognizer() else {
            throw VoiceError("The macOS voice command recognizer is unavailable. Retry after checking the microphone.")
        }
        matcher.commands = ["Hey Vayde", "Hey Vade"]
        matcher.displayedCommandsTitle = "VaydeAOS"
        matcher.listensInForegroundOnly = false
        matcher.blocksOtherRecognizers = false
        matcher.delegate = self
        wakeHandler = onWake
        wakeRecognizer = matcher
        matcher.startListening()
    }

    func stopWakeListening() {
        wakeHandler = nil
        wakeRecognizer?.stopListening()
        wakeRecognizer?.delegate = nil
        wakeRecognizer = nil
    }

    func speechRecognizer(_ sender: NSSpeechRecognizer, didRecognizeCommand command: String) {
        guard sender === wakeRecognizer else { return }
        wakeHandler?()
    }

    func startTranscription(onUpdate: @escaping (String, Bool) -> Void,
                            onFailure: @escaping (String) -> Void) throws {
        stopTranscription()
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw VoiceError("On-device speech recognition is unavailable. Retry when the Mac's speech service is ready.")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError("No microphone input is available. Connect or select a microphone, then retry.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Vayde", "VaydeAOS", "VaydeNet"]
        let token = recognitionID
        self.engine = engine
        recognitionRequest = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Recognition callbacks arrive off the main thread. Ignore every cancelled session.
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.recognitionID == token else { return }
                if let text { onUpdate(text, final) }
                if let failure, !final, self.recognitionID == token {
                    onFailure("Speech recognition stopped: \(failure)")
                }
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.recognitionID == token else { return }
                onFailure("The microphone configuration changed. Retry with the current audio device.")
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stopTranscription()
            throw VoiceError("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    func stopTranscription() {
        recognitionID = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    func speak(_ text: String, onFinished: @escaping () -> Void) {
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: VoiceSpeechText.readable(text))
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        spokenUtterance = utterance
        speechFinished = onFinished
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        speechFinished = nil
        spokenUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.spokenUtterance === utterance else { return }
            let completion = self.speechFinished
            self.speechFinished = nil
            self.spokenUtterance = nil
            completion?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speechSynthesizer(synthesizer, didFinish: utterance)
    }

    private func observeWorkspace(_ name: Notification.Name, reason: String, suspended: Bool) {
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSuspension(reason, suspended: suspended) }
        })
    }

    private func observeLock(_ name: String, suspended: Bool) {
        lockObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSuspension("lock", suspended: suspended) }
        })
    }

    private func updateSuspension(_ reason: String, suspended: Bool) {
        let wasSuspended = !suspensions.isEmpty
        if suspended { suspensions.insert(reason) } else { suspensions.remove(reason) }
        if wasSuspended != !suspensions.isEmpty { onSuspensionChange?(!suspensions.isEmpty) }
    }
}

private struct VoiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
