import AppKit
import SwiftUI
import VaydeAOSCore

@main
struct VaydeAOSApp: App {
    @NSApplicationDelegateAdaptor(VaydeAOSAppDelegate.self) private var appDelegate
    @StateObject private var session = ChatSession()
    @State private var showingConnectionSettings = false

    var body: some Scene {
        Window("VaydeAOS", id: "chat") {
            ChatView(session: session, showingConnectionSettings: $showingConnectionSettings)
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
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Connection Settings…") {
                    showingConnectionSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(session.isSending)
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
