import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VaydeAOSCore

/// System output only. No microphone, recording file, or video output is attached.
@MainActor
final class SystemAudioSpectrum: ObservableObject {
    @Published private(set) var bands = [Double](repeating: 0, count: 72)
    @Published private(set) var level: Double = 0
    @Published private(set) var enabled = false
    @Published private(set) var running = false
    @Published private(set) var status = "AUDIO OFF"
    @Published private(set) var needsPermission = false
    private var lastSampleAt = Date.distantPast
    private var active = false
    private var stream: SCStream?
    private var output: AudioSpectrumOutput?
    private var generation = UUID()

    func toggle() async {
        enabled.toggle()
        if enabled && !CGPreflightScreenCaptureAccess() {
            // Permission is requested only by the explicit Enable audio control.
            _ = CGRequestScreenCaptureAccess()
        }
        await reconcile()
    }

    func setActive(_ value: Bool) async { active = value; await reconcile() }

    private func reconcile() async {
        let token = UUID(); generation = token
        let old = stream; stream = nil; output = nil
        running = false; level = 0; bands = .init(repeating: 0, count: 72)
        if let old { try? await old.stopCapture() }
        guard generation == token else { return }
        guard enabled else { status = "AUDIO OFF"; needsPermission = false; return }
        guard active else { status = "PAUSED"; return }
        guard CGPreflightScreenCaptureAccess() else {
            needsPermission = true; status = "ALLOW SYSTEM AUDIO IN SETTINGS"; return
        }
        needsPermission = false; status = "CONNECTING AUDIO"
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard generation == token, active, enabled else { return }
            guard let display = content.displays.first else { status = "NO AUDIO SOURCE"; return }
            let configuration = SCStreamConfiguration()
            configuration.width = 2; configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000; configuration.channelCount = 2
            let sink = AudioSpectrumOutput(onLevels: { [weak self] bands, rms in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.running else { return }
                    self.bands = zip(self.bands, bands).map { previous, current in
                        current > previous ? previous * 0.25 + current * 0.75 : previous * 0.72 + current * 0.28
                    }
                    self.lastSampleAt = Date()
                    self.level = rms
                    self.status = rms > 0.0001 ? "SYSTEM AUDIO / LIVE" : "SYSTEM AUDIO / SILENT"
                }
            }, onFailure: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.running = false; self.level = 0
                    self.bands = .init(repeating: 0, count: 72)
                    self.status = "AUDIO DISCONNECTED / RETRY"
                    self.stream = nil; self.output = nil; self.enabled = false
                }
            })
            let candidate = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                     configuration: configuration, delegate: sink)
            try candidate.addStreamOutput(sink, type: .audio,
                                          sampleHandlerQueue: DispatchQueue(label: "VaydeAOS.audio-spectrum", qos: .userInitiated))
            try await candidate.startCapture()
            guard generation == token, active, enabled else { try? await candidate.stopCapture(); return }
            output = sink; stream = candidate; running = true; status = "SYSTEM AUDIO / SILENT"
        } catch {
            guard generation == token else { return }
            status = "AUDIO UNAVAILABLE / RETRY"; enabled = false
        }
    }

    func decayIfQuiet(at date: Date) {
        guard running, date.timeIntervalSince(lastSampleAt) > 0.2 else { return }
        bands = bands.map { $0 < 0.002 ? 0 : $0 * 0.75 }
        level = level < 0.00001 ? 0 : level * 0.75
        if level < 0.0001 { status = "SYSTEM AUDIO / SILENT" }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class AudioSpectrumOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let onLevels: ([Double], Double) -> Void
    let onFailure: () -> Void
    private var pending = [[Float](), [Float]()]
    private var lastAnalysis: TimeInterval = 0

    init(onLevels: @escaping ([Double], Double) -> Void, onFailure: @escaping () -> Void) {
        self.onLevels = onLevels; self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.commonFormat == .pcmFormatFloat32 else { return }
        let count = sampleBuffer.numSamples
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count),
                                                         into: pcm.mutableAudioBufferList) == noErr,
              let channels = pcm.floatChannelData else { return }
        let channelCount = min(2, Int(format.channelCount))
        for channel in 0..<channelCount {
            let data = format.isInterleaved ? channels[0].advanced(by: channel) : channels[channel]
            for frame in 0..<count { pending[channel].append(data[frame * pcm.stride]) }
            if pending[channel].count > 2048 { pending[channel].removeFirst(pending[channel].count - 2048) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAnalysis >= 1 / 30, pending[0].count >= 2048 else { return }
        lastAnalysis = now
        let spectra = (0..<channelCount).map { AudioSpectrum(samples: pending[$0], sampleRate: format.sampleRate) }
        var bands = [Double](repeating: 0, count: 72)
        for spectrum in spectra { bands = zip(bands, spectrum.bands).map { max($0, $1) } }
        let rms = sqrt(spectra.reduce(0) { $0 + $1.rms * $1.rms } / Double(max(1, channelCount)))
        onLevels(bands, rms)
    }
}
