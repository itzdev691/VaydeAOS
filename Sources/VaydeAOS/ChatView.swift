import AppKit
import SwiftUI
import VaydeAOSCore

struct ChatView: View {
    @ObservedObject var session: ChatSession
    @Binding var showingConnectionSettings: Bool
    @StateObject private var telemetry = SystemTelemetry()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composerFocused: Bool
    @State private var workspaceMode = WorkspaceMode.workspace
    @State private var animateNetwork = true

    private enum WorkspaceMode: String, CaseIterable {
        case workspace = "WORKSPACE", network = "NETWORK", focus = "FOCUS"
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                navigation
                HStack(alignment: .top, spacing: 12) {
                    if workspaceMode != .focus {
                        TelemetrySidebar(telemetry: telemetry)
                            .frame(width: geometry.size.width < 1250 ? 208 : 238)
                    }
                    VStack(spacing: 12) {
                        if workspaceMode != .focus {
                            networkPanel
                                .frame(height: workspaceMode == .network ? max(310, geometry.size.height * 0.53) : max(230, min(310, geometry.size.height * 0.35)))
                        }
                        conversationPanel
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if geometry.size.width >= 1250 && workspaceMode != .focus {
                        SessionSidebar(session: session, telemetry: telemetry, showingConnectionSettings: $showingConnectionSettings)
                            .frame(width: 238)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .background {
                Console.background
                RadialGradient(colors: [Console.blueStrong.opacity(0.16), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 650)
                ConsoleGrid()
            }
        }
        .foregroundStyle(Console.text)
        .tint(Console.blue)
        .preferredColorScheme(.dark)
        .onAppear { composerFocused = true; telemetry.start() }
        .onDisappear { telemetry.stop() }
        .onChange(of: scenePhase) { phase in
            if phase == .background { telemetry.stop() } else { telemetry.start() }
        }
        .onChange(of: session.isSending) { sending in
            if !sending && !showingConnectionSettings { composerFocused = true }
        }
        .onChange(of: showingConnectionSettings) { showing in
            if !showing { composerFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Console.image("vayde-mark", extension: "png")
                .resizable().scaledToFit().frame(width: 39, height: 39)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("VAYDE").font(.system(size: 25, weight: .bold, design: .monospaced)).tracking(2)
                Text("AOS").font(.system(size: 25, weight: .light, design: .monospaced)).tracking(2).foregroundStyle(Console.blue)
            }
            Rectangle().fill(Console.line).frame(width: 1, height: 28).padding(.horizontal, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text("AGENT OPERATING SYSTEM").tracking(2).font(Console.mono(9, weight: .medium))
                Text("Your intent. One command center.").font(Console.mono(10)).foregroundStyle(Console.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, style: .time).font(Console.mono(18, weight: .light)).monospacedDigit()
                }
                Text("LOCAL WORKSPACE / macOS").tracking(1).font(Console.mono(9)).foregroundStyle(Console.muted)
            }
            Button { showingConnectionSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15)).frame(width: 20, height: 20)
            }
            .buttonStyle(ConsoleButtonStyle()).padding(.leading, 12)
            .disabled(session.isSending).help("Connection settings (Command-comma)").accessibilityLabel("Connection settings")
        }
        .padding(.horizontal, 22).frame(height: 80)
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceMode.allCases, id: \.self) { mode in
                Button { workspaceMode = mode } label: {
                    HStack(spacing: 8) {
                        Text(mode == .workspace ? "01" : mode == .network ? "02" : "03").foregroundStyle(Console.muted)
                        Text(mode.rawValue).tracking(1.5)
                    }
                    .font(Console.mono(10, weight: .medium)).padding(.horizontal, 20)
                    .frame(height: 41)
                    .foregroundStyle(workspaceMode == mode ? Console.blue : Console.muted)
                    .background(workspaceMode == mode ? Console.blue.opacity(0.07) : .clear)
                    .overlay(alignment: .bottom) { if workspaceMode == mode { Rectangle().fill(Console.red).frame(height: 2) } }
                }
                .buttonStyle(.plain).accessibilityAddTraits(workspaceMode == mode ? .isSelected : [])
            }
            Spacer()
            Circle().fill(telemetry.isNetworkAvailable ? Console.green : Console.amber).frame(width: 5, height: 5)
            Text(telemetry.pathStatus.uppercased()).font(Console.mono(9)).tracking(1).padding(.leading, 7).padding(.trailing, 20)
        }
        .background(Console.panel)
        .overlay(alignment: .top) { Rectangle().fill(Console.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Console.line).frame(height: 1) }
    }

    private var networkPanel: some View {
        ConsolePanel(title: "NETWORK OBSERVATORY", index: "01", status: telemetry.primaryInterfaceName?.uppercased() ?? "NO ROUTE") {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("BEYOND\nBOUNDARIES.")
                        .font(.system(size: 24, weight: .light, design: .monospaced)).tracking(0.5).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    Text("VAYDENET / TRANSPORT LAYER").font(Console.mono(8)).foregroundStyle(Console.red).tracking(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Circle().fill(telemetry.isNetworkAvailable ? Console.green : Console.amber).frame(width: 5, height: 5)
                        Text(telemetry.isNetworkAvailable ? "NETWORK AVAILABLE" : "NETWORK UNAVAILABLE")
                            .font(Console.mono(8)).foregroundStyle(Console.muted)
                    }
                    Text("\(telemetry.interfaces.filter { $0.isUp }.count) active interfaces")
                        .font(Console.mono(11)).foregroundStyle(Console.text)
                    Button { animateNetwork.toggle() } label: {
                        Label(animateNetwork ? "PAUSE ORBIT" : "RESUME ORBIT", systemImage: animateNetwork ? "pause" : "play")
                    }
                    .buttonStyle(ConsoleButtonStyle()).help("Pause or resume the illustrative globe animation")
                }
                .frame(width: 195, alignment: .leading).padding(16)
                NetworkGlobeView(isActive: animateNetwork && scenePhase != .background, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ConsoleGrid())
        }
    }

    private var conversationPanel: some View {
        ConsolePanel(title: "COMMAND CHANNEL", index: "02", status: session.isSending ? "RUNNING" : "STANDBY") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Console.blue)
                    Text(session.settings.model).foregroundStyle(Console.text).lineLimit(1)
                    Text("/ \(session.messages.count) messages").foregroundStyle(Console.muted)
                    Spacer()
                    Button { session.newChat(); composerFocused = true } label: {
                        Label("NEW CHAT", systemImage: "plus")
                    }
                    .buttonStyle(.plain).foregroundStyle(Console.blue).help("New chat (Command-N)").accessibilityLabel("New chat")
                }
                .font(Console.mono(10)).padding(.horizontal, 16).frame(height: 38)
                .background(Console.background.opacity(0.45))
                Group {
                    if session.messages.isEmpty && session.pendingMessage == nil {
                        if workspaceMode != .network { ScrollView { emptyConversation } }
                    } else { transcript }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                composer
            }
        }
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(">").foregroundStyle(Console.blue)
                Text("Intent becomes action.").foregroundStyle(Console.text)
            }.font(Console.mono(20, weight: .light))
            Text("A direct line to your model. Start with a question,\nan idea, or the next thing you want to build.")
                .font(Console.mono(11)).foregroundStyle(Console.muted).lineSpacing(5)
            HStack(spacing: 7) {
                promptButton("Explore an idea", prompt: "Help me explore an idea. Start by asking what I want to build.")
                promptButton("Break down a task", prompt: "Help me break a task into clear, practical steps.")
            }.padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }

    private func promptButton(_ title: String, prompt: String) -> some View {
        Button { session.draft = prompt; composerFocused = true } label: { Text(title) }
            .buttonStyle(ConsoleButtonStyle()).disabled(session.isSending)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(session.messages) { MessageRow(message: $0) }
                    if let message = session.pendingMessage { MessageRow(message: message) }
                    if session.isSending {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Awaiting model response…").font(Console.mono(11)).foregroundStyle(Console.blue)
                            Spacer()
                        }
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom").accessibilityHidden(true)
                }.padding(18)
            }
            .accessibilityLabel("Conversation")
            .onAppear { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            .onChange(of: session.messages.count) { _ in scrollToBottom(proxy) }
            .onChange(of: session.pendingMessage?.id) { _ in scrollToBottom(proxy) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let notice = session.notice {
                Text(notice).font(Console.mono(10)).foregroundStyle(Console.muted).textSelection(.enabled)
            }
            if let error = session.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Console.amber)
                    Text(error).font(Console.mono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { session.dismissError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }.foregroundStyle(Console.amber).padding(10).background(Console.amber.opacity(0.08))
            }
            HStack(alignment: .top, spacing: 8) {
                Text(">").font(Console.mono(17)).foregroundStyle(Console.blue).padding(.top, 6)
                ZStack(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text("Enter a command or ask anything…").font(Console.mono(12))
                            .foregroundStyle(Console.muted).padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false)
                    }
                    TextEditor(text: $session.draft)
                        .font(Console.mono(12)).scrollContentBackground(.hidden).focused($composerFocused)
                        .disabled(session.isSending).frame(minHeight: 44, maxHeight: 68)
                        .accessibilityLabel("Message").accessibilityHint("Command-Return to send")
                }
            }
            HStack {
                Text("TEXT CHANNEL").tracking(1).foregroundStyle(Console.muted)
                Spacer()
                Text("⌘ ↵").foregroundStyle(Console.muted).padding(.trailing, 4)
                if session.isSending {
                    Button { session.stop() } label: { Label("STOP", systemImage: "stop.fill") }
                        .buttonStyle(ConsoleButtonStyle()).keyboardShortcut(.escape, modifiers: []).accessibilityLabel("Stop response")
                } else {
                    Button { session.send() } label: { Label("TRANSMIT", systemImage: "arrow.up.right") }
                        .buttonStyle(ConsoleButtonStyle(prominent: true)).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!session.canSend).accessibilityLabel("Send message")
                }
            }.font(Console.mono(9))
        }
        .padding(12).background(Console.background.opacity(0.7))
        .overlay(Rectangle().strokeBorder(composerFocused ? Console.red.opacity(0.55) : Console.line, lineWidth: 1))
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Console.blue).frame(width: 4, height: 4)
            Text("VAYDE AOS").tracking(1)
            Text("/  NATIVE CONSOLE").foregroundStyle(Console.muted)
            Spacer()
            Text(session.isSending ? "MODEL REQUEST IN PROGRESS" : "AWAITING INPUT").foregroundStyle(session.isSending ? Console.amber : Console.muted)
            Rectangle().fill(Console.line).frame(width: 1, height: 10).padding(.horizontal, 8)
            Text("TELEMETRY \(telemetry.lastUpdated == nil ? "INITIALIZING" : "LIVE")").foregroundStyle(Console.blue)
        }
        .font(Console.mono(9)).padding(.horizontal, 20).frame(height: 30)
        .background(Console.panel).overlay(alignment: .top) { Rectangle().fill(Console.line).frame(height: 1) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
        else { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    @State private var copied = false
    private var isUser: Bool { message.role == .user }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(isUser ? "YOU" : "AGENT").tracking(1.5).foregroundStyle(isUser ? Console.muted : Console.blue)
                Rectangle().fill(Console.line).frame(height: 1)
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(message.content, forType: .string)
                } label: {
                    Label(copied ? "COPIED" : "COPY", systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.plain).foregroundStyle(Console.muted).help("Copy message")
            }.font(Console.mono(9, weight: .medium))
            Text(message.content).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12).padding(.vertical, 5)
        .overlay(alignment: .leading) { Rectangle().fill(isUser ? Console.line : Console.blue.opacity(0.5)).frame(width: 2) }
        .accessibilityElement(children: .contain).accessibilityLabel(isUser ? "Your message" : "Assistant message")
    }
}
