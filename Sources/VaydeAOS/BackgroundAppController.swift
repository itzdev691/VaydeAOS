import AppKit
import ServiceManagement
import SwiftUI

/// Keeps window presentation separate from the lifetime of the resident app and its services.
@MainActor
final class BackgroundAppController: ObservableObject {
    @Published private(set) var workspaceVisible = true
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var loginError: String?
    private var workspaceWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var launchedHidden = false
    private var windowRegistered = false
    var openWindow: (() -> Void)?

    var launchesAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func didLaunch(inBackground: Bool) {
        launchedHidden = inBackground
        NSApp.setActivationPolicy(.accessory)
        if inBackground { hideWorkspace() }
        else { showWorkspace() }
    }

    func registerWindow(_ window: NSWindow) {
        guard workspaceWindow !== window else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        workspaceWindow = window
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        observe(NSWindow.willCloseNotification, window: window) { [weak self] in self?.workspaceVisible = false }
        observe(NSWindow.didBecomeKeyNotification, window: window) { [weak self] in
            guard let self else { return }
            if self.launchedHidden { self.hideWorkspace() } else { self.workspaceVisible = true }
        }
        observe(NSWindow.didMiniaturizeNotification, window: window) { [weak self] in self?.workspaceVisible = false }
        observe(NSWindow.didDeminiaturizeNotification, window: window) { [weak self] in self?.workspaceVisible = true }
        if !windowRegistered, launchedHidden {
            hideWorkspace()
        } else { workspaceVisible = window.isVisible }
        windowRegistered = true
    }

    func showWorkspace(openChat: Bool = false) {
        launchedHidden = false
        workspaceVisible = true
        if let window = workspaceWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else { self.openWindow?() }
        NSApp.activate(ignoringOtherApps: true)
        if openChat {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .vaydeOpenChat, object: nil) }
        }
    }

    func hideWorkspace() {
        workspaceVisible = false
        workspaceWindow?.orderOut(nil)
    }

    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }

    func setLaunchesAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled {
                let status = SMAppService.mainApp.status
                if status != .enabled, status != .requiresApproval { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        } catch { loginError = "Could not change Launch at Login: \(error.localizedDescription)" }
        refreshLoginStatus()
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func observe(_ name: Notification.Name, window: NSWindow, action: @escaping () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

private struct WorkspaceVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var workspaceWindowVisible: Bool {
        get { self[WorkspaceVisibleKey.self] }
        set { self[WorkspaceVisibleKey.self] = newValue }
    }
}

struct BackgroundWindowBridge: ViewModifier {
    @ObservedObject var controller: BackgroundAppController
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .environment(\.workspaceWindowVisible, controller.workspaceVisible)
            .background(BackgroundWindowReader(onWindow: controller.registerWindow))
            .onAppear { controller.openWindow = { openWindow(id: "chat") } }
    }
}

private struct BackgroundWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ view: WindowView, context: Context) { view.onWindow = onWindow }

    final class WindowView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                if let window { self?.onWindow?(window) }
            }
        }
    }
}
