import AppKit
import SwiftUI

/// Tracks activity only in this window; a wake event can be consumed before routing.
struct WorkspaceInputMonitor: NSViewRepresentable {
    var onActivity: (NSEvent) -> Bool

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.onActivity = onActivity
    }

    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stopMonitoring() }

    final class InputView: NSView {
        var onActivity: (NSEvent) -> Bool = { _ in false }
        private var monitor: Any?
        private weak var monitoredWindow: NSWindow?
        private var previouslyAcceptedMouseMoves = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard let window else { return }
            monitoredWindow = window
            previouslyAcceptedMouseMoves = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged,
                .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                return self.onActivity(event) ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            monitoredWindow?.acceptsMouseMovedEvents = previouslyAcceptedMouseMoves
            monitoredWindow = nil
        }

        deinit { stopMonitoring() }
    }
}
