import AppKit
import SwiftUI
import VaydeAOSCore

@main
struct VaydeAOSApp: App {
    @NSApplicationDelegateAdaptor(VaydeAOSAppDelegate.self) private var appDelegate
    @StateObject private var session = ChatSession()
    @State private var showingConnectionSettings = false
    @State private var startupComplete = false
    @AppStorage("startup.soundEnabled") private var startupSoundEnabled = true

    var body: some Scene {
        Window("VaydeAOS", id: "chat") {
            StartupContainer(isComplete: $startupComplete) {
                ChatView(session: session, showingConnectionSettings: $showingConnectionSettings)
            }
            .frame(minWidth: 1080, minHeight: 780)
            .sheet(isPresented: $showingConnectionSettings) {
                ConnectionSettingsView(session: session)
            }
        }
        .defaultSize(width: 1460, height: 980)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    session.newChat()
                    NotificationCenter.default.post(name: .vaydeOpenChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!startupComplete)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Connection Settings…") {
                    showingConnectionSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(!startupComplete || session.isSending)
                Divider()
                Toggle("Startup Sound", isOn: $startupSoundEnabled)
            }
        }
    }
}

final class VaydeAOSAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Notification.Name {
    static let vaydeOpenChat = Notification.Name("VaydeAOS.openChat")
}
