import AppKit
import Foundation

// Compile with BackgroundAppController.swift. Exercises native windows without registering login items.
@main
struct BackgroundAppCheck {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        let controller = BackgroundAppController()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "VaydeAOS background lifecycle check"
        controller.registerWindow(window)
        controller.didLaunch(inBackground: false)
        try require(app.activationPolicy() == .accessory, "App must use accessory activation policy")
        try require(window.isVisible && controller.workspaceVisible, "Manual launch must show the workspace")

        window.performClose(nil)
        try require(!window.isVisible && !controller.workspaceVisible, "Closing must mark the workspace hidden")
        controller.showWorkspace()
        try require(window.isVisible && controller.workspaceVisible, "A closed workspace must reopen")
        controller.hideWorkspace()
        try require(!window.isVisible && !controller.workspaceVisible, "Hide must not destroy the window")
        controller.showWorkspace()
        try require(window.isVisible, "A hidden workspace must reopen")

        controller.didLaunch(inBackground: true)
        try require(!window.isVisible && !controller.workspaceVisible, "Background launch must keep the workspace hidden")
        controller.showWorkspace()
        try require(window.isVisible, "Explicit opening must work after a background launch")
        window.close()
        print("PASS: accessory policy, close/reopen, hide/show, background launch and explicit opening")
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "VaydeAOS.BackgroundCheck", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

extension Notification.Name {
    static let vaydeOpenChat = Notification.Name("VaydeAOS.openChat")
}
