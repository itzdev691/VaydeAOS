import AppKit
import SwiftUI
import VaydeAOSCore

struct VoiceAssistantButton: View {
    @ObservedObject var voice: VoiceAssistant
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: voice.isEnabled ? "mic" : "mic.slash")
                .font(.system(size: 14)).frame(width: 20, height: 20)
                .foregroundStyle(voice.phase == .unavailable ? Console.amber : voice.isInteracting ? Console.red : Console.blue)
        }
        .buttonStyle(ConsoleButtonStyle())
        .help(voice.statusText)
        .accessibilityLabel("Vayde Voice: \(voice.statusText)")
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 14) {
                Text("VAYDE VOICE").font(Console.mono(12)).tracking(2).foregroundStyle(Console.blue)
                VoiceAssistantActions(voice: voice)
                Text("Say “Hey Vayde”, wait for “Yes?”, then speak. Your request uses the current chat’s model and tools.")
                    .font(.system(size: 12)).foregroundStyle(Console.muted)
                Text("Voice stays available when this window is closed. Quit VaydeAOS to stop it.")
                    .font(.system(size: 11)).foregroundStyle(Console.muted)
            }
            .padding(20).frame(width: 340).foregroundStyle(Console.text).background(Console.panel)
            .preferredColorScheme(.dark)
        }
    }
}

struct VoiceAssistantActions: View {
    @ObservedObject var voice: VoiceAssistant

    var body: some View {
        Toggle("Listen for “Hey Vayde”", isOn: Binding(get: { voice.isEnabled }, set: voice.setEnabled))
        Text(voice.statusText).font(.system(size: 12))
        if let issue = voice.issue {
            Text(issue).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if voice.phase == .listening, !voice.transcript.isEmpty {
            Text(voice.transcript).font(.system(size: 12)).lineLimit(4)
            Button("Send Voice Request") { voice.finishListening() }
        }
        if voice.phase == .unavailable { Button("Retry Voice Access") { voice.retry() } }
        Button("Speak to Vayde") { voice.listenNow() }.disabled(voice.phase != .waitingForWake)
        if voice.isInteracting { Button("Stop Voice Turn") { voice.cancelInteraction() } }
    }
}

struct VoiceAssistantMenu: View {
    @ObservedObject var voice: VoiceAssistant
    @ObservedObject var background: BackgroundAppController

    var body: some View {
        Button("Open VaydeAOS") { background.showWorkspace() }
        Button("Hide Window") { background.hideWorkspace() }.disabled(!background.workspaceVisible)
        Divider()
        Menu("Vayde Voice") { VoiceAssistantActions(voice: voice) }
        Toggle("Launch at Login", isOn: Binding(get: { background.launchesAtLogin }, set: background.setLaunchesAtLogin))
        if background.loginStatus == .requiresApproval {
            Text("Launch at Login requires approval in System Settings")
            Button("Open Login Items Settings") { background.openLoginSettings() }
        }
        if let error = background.loginError {
            Text(error)
            Button("Open Login Items Settings") { background.openLoginSettings() }
        }
        Divider()
        Button("Quit VaydeAOS") { NSApp.terminate(nil) }.keyboardShortcut("q")
            .onAppear { background.refreshLoginStatus() }
    }
}
