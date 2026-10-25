import AppKit
import SwiftUI

/// Window-local interaction routing. Never monitors typing in other applications.
struct WorkspaceInputMonitor: NSViewRepresentable {
    var onActivity: () -> Void
    var onTyping: (String) -> Bool

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.onActivity = onActivity
        view.onTyping = onTyping
    }

    final class InputView: NSView {
        var onActivity: () -> Void = {}
        var onTyping: (String) -> Bool = { _ in false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                self.onActivity()
                guard event.type == .keyDown,
                      !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
                      !event.modifierFlags.contains(.option),
                      !(self.window?.firstResponder is NSTextView),
                      let text = event.characters, !text.isEmpty,
                      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }),
                      self.onTyping(text) else { return event }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
