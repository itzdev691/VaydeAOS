import AppKit
import Combine

/// Retains the short local startup cue for the lifetime of its owning view.
@MainActor
final class StartupSound: ObservableObject {
    private var sound: NSSound?

    func play() {
        if sound == nil,
           let url = Console.assets.url(forResource: "startup-chime", withExtension: "wav") {
            sound = NSSound(contentsOf: url, byReference: false)
            sound?.volume = 0.8
        }
        guard let sound, !sound.isPlaying else { return }
        sound.currentTime = 0
        sound.play()
    }

    func stop() {
        sound?.stop()
        sound?.currentTime = 0
    }
}
