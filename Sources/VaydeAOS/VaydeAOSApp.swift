import AppKit
import SwiftUI
import VaydeAOSCore

@main
struct VaydeAOSApp: App {
    @NSApplicationDelegateAdaptor(VaydeAOSAppDelegate.self) private var appDelegate
    private var session: ChatSession { appDelegate.session }
    private var voice: VoiceAssistant { appDelegate.voice }
    @State private var showingConnectionSettings = false
    @State private var startupComplete = false
    @AppStorage("startup.soundEnabled") private var startupSoundEnabled = true

    var body: some Scene {
        Window("VaydeAOS", id: "chat") {
            StartupContainer(isComplete: $startupComplete) {
                ChatView(session: session, projectConsoles: appDelegate.projectConsoles,
                         showingConnectionSettings: $showingConnectionSettings)
            }
            .environmentObject(voice)
            .modifier(BackgroundWindowBridge(controller: appDelegate.background))
            .frame(minWidth: 1080, minHeight: 780)
            .sheet(isPresented: $showingConnectionSettings) {
                ConnectionSettingsView(session: session)
            }
            .onChange(of: showingConnectionSettings) { voice.setInteractionBlocked($0) }
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
                .disabled(!startupComplete || !session.canOrganizeChats)
            }
            CommandGroup(after: .toolbar) {
                Button("Ambient Display") {
                    NotificationCenter.default.post(name: .vaydeShowIdle, object: nil)
                }.keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!startupComplete || session.isSending || showingConnectionSettings)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Connection Settings…") {
                    showingConnectionSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(!startupComplete || session.isSending)
                Divider()
                Toggle("Startup Sound", isOn: $startupSoundEnabled)
                Toggle("Listen for “Hey Vayde”", isOn: Binding(get: { voice.isEnabled }, set: voice.setEnabled))
            }
        }
        MenuBarExtra {
            VoiceAssistantMenu(voice: voice, background: appDelegate.background)
        } label: {
            Console.image("vayde-mark", extension: "png")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .accessibilityLabel("VaydeAOS")
        }
    }
}

private func legacyConsoleState() -> WorkspaceConsoleState {
    let defaults = UserDefaults.standard
    var console = WorkspaceConsoleState()
    console.scratchpad = defaults.string(forKey: "workspace.scratchpad") ?? ""
    console.autoIdle = defaults.object(forKey: "workspace.autoIdle") as? Bool ?? true
    console.sidebarVisible = defaults.object(forKey: "chat.sidebarVisible") as? Bool ?? true
    return console
}

@MainActor
final class VaydeAOSAppDelegate: NSObject, NSApplicationDelegate {
    let session: ChatSession
    let voice: VoiceAssistant
    let background = BackgroundAppController()
    let projectConsoles = ProjectConsoleRegistry()

    override init() {
        let session = ChatSession(legacyConsole: legacyConsoleState())
        self.session = session
        voice = VoiceAssistant(session: session, audio: MacVoiceAudio())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        background.didLaunch(inBackground: loginLaunch || CommandLine.arguments.contains("--background"))
        voice.onActivation = { [weak self] in self?.background.showWorkspace(openChat: true) }
        if ProcessInfo.processInfo.environment["VAYDEAOS_DISABLE_VOICE"] != "1" { voice.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        background.showWorkspace()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        voice.shutdown()
        session.saveDraft()
        projectConsoles.shutdown()
        session.codex.shutdown()
    }
}

extension Notification.Name {
    static let vaydeShowIdle = Notification.Name("VaydeAOS.showIdle")
    static let vaydeOpenChat = Notification.Name("VaydeAOS.openChat")
}
