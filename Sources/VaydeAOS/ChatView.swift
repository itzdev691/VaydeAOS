import AppKit
import SwiftUI
import VaydeAOSCore

struct ChatView: View {
    @ObservedObject var session: ChatSession
    @Binding var showingConnectionSettings: Bool
    @StateObject private var telemetry = SystemTelemetry()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceBootReady) private var bootReady
    @State private var bootStep = 0
    @FocusState private var composerFocused: Bool
    @State private var workspaceMode = WorkspaceMode.workspace
    @State private var chatPresented = false
    @State private var lastInteraction = Date()
    @State private var events = [WorkspaceEvent(title: "Workspace initialized")]
    @AppStorage("workspace.autoIdle") private var autoIdle = true
    private let idleTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum WorkspaceMode: String, CaseIterable {
        case workspace = "WORKSPACE", network = "NETWORK", focus = "FOCUS"
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.workspaceBoot(stage: 0, label: "DISPLAY")
                navigation.workspaceBoot(stage: 1, label: "NAVIGATION")
                HStack(alignment: .top, spacing: 12) {
                    if workspaceMode != .focus {
                        TelemetrySidebar(telemetry: telemetry)
                            .workspaceBoot(stage: 2, label: "HOST INSTRUMENTS")
                            .frame(width: geometry.size.width < 1250 ? 208 : 238)
                    }
                    ZStack {
                        // Keep the dashboard mounted so timers and widget state survive chat.
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 12) {
                                idleBanner.workspaceBoot(stage: 3, label: "WORKSPACE")
                                activityGraphPanel.frame(height: workspaceMode == .network ? 300 : 230)
                                WorkspaceWidgets(isActive: !chatPresented, events: events,
                                                 interrupt: { openChat(prompt: $0) }, record: record)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(chatPresented ? 0 : 1)
                        .allowsHitTesting(!chatPresented)
                        .accessibilityHidden(chatPresented)
                        if chatPresented {
                            VStack(spacing: 12) {
                                HStack {
                                    Circle().fill(Console.green).frame(width: 5, height: 5)
                                    Text("CHANNEL OPEN").tracking(1.2)
                                    Spacer()
                                    Button { enterIdle() } label: {
                                        Label("RETURN TO IDLE", systemImage: "square.grid.2x2")
                                    }.buttonStyle(ConsoleButtonStyle()).help("Show the dashboard; keep the conversation and draft")
                                }.font(Console.mono(9)).foregroundStyle(Console.blue)
                                conversationPanel
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if geometry.size.width >= 1250 && workspaceMode != .focus {
                        SessionSidebar(session: session, telemetry: telemetry, showingConnectionSettings: $showingConnectionSettings)
                            .frame(width: 238)
                            .workspaceBoot(stage: 3, label: "SESSION")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer.workspaceBoot(stage: 10, label: "STATUS BAR")
            }
            .background {
                Console.background
                RadialGradient(colors: [Console.blueStrong.opacity(0.16), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 650)
                ConsoleGrid()
            }
        }
        .environment(\.workspaceBootStep, reduceMotion ? 11 : bootStep)
        .task(id: bootReady) {
            guard bootReady else { return }
            if reduceMotion { bootStep = 11; return }
            guard bootStep < 11 else { return }
            do {
                for step in 1...11 {
                    try await Task.sleep(nanoseconds: 220_000_000)
                    try Task.checkCancellation()
                    bootStep = step
                }
            } catch { }
        }
        .onChange(of: reduceMotion) { reduced in
            if reduced { bootStep = 11 }
        }
        .foregroundStyle(Console.text)
        .tint(Console.blue)
        .preferredColorScheme(.dark)
        .background(WorkspaceInputMonitor(onActivity: { lastInteraction = Date() }, onTyping: { text in
            guard bootReady, (reduceMotion || bootStep == 11), !chatPresented, !showingConnectionSettings else { return false }
            openChat()
            session.draft += text
            return true
        }))
        .background {
            Button("Interrupt") { openChat() }.keyboardShortcut("k", modifiers: .command).hidden()
        }
        .onExitCommand {
            if chatPresented {
                if session.isSending { session.stop() } else { enterIdle() }
            }
        }
        .onReceive(idleTicker) { date in
            if autoIdle, chatPresented, !showingConnectionSettings, !session.isSending,
               session.draft.isEmpty, session.errorMessage == nil, date.timeIntervalSince(lastInteraction) >= 60 {
                enterIdle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaydeOpenChat)) { _ in openChat() }
        .onAppear {
            telemetry.start()
            if session.errorMessage != nil || !session.draft.isEmpty { openChat() }
        }
        .onDisappear { telemetry.stop() }
        .onChange(of: scenePhase) { phase in
            if phase == .background { telemetry.stop() } else { telemetry.start() }
        }
        .onChange(of: session.isSending) { sending in
            lastInteraction = Date()
            record(sending ? "Model request started" : "Model request finished")
            if !sending { openChat() }
        }
        .onChange(of: session.errorMessage) { error in
            if error != nil { record("Model channel needs attention"); openChat() }
        }
        .onChange(of: showingConnectionSettings) { showing in
            if !showing && chatPresented { composerFocused = true }
        }
    }

    private var idleBanner: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle().stroke(Console.blue.opacity(0.15), lineWidth: 1).frame(width: 54, height: 54)
                Circle().stroke(Console.blue.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 5])).frame(width: 42, height: 42)
                Image(systemName: "waveform.path").font(.system(size: 19, weight: .light)).foregroundStyle(Console.blue)
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("SYSTEM AT IDLE").font(Console.mono(21, weight: .light)).tracking(2)
                Text("Instruments live. Interrupt to open your command channel.")
                    .font(Console.mono(10)).foregroundStyle(Console.muted)
            }
            Spacer(minLength: 0)
            Toggle("AUTO IDLE", isOn: $autoIdle).toggleStyle(.switch).controlSize(.mini)
                .font(Console.mono(8)).fixedSize().help("Return to idle after 60 seconds with no input, unsent draft, error, or active request")
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Console.raised.opacity(0.25)).overlay(Rectangle().strokeBorder(Console.line, lineWidth: 1))
    }

    private func openChat(prompt: String? = nil) {
        if let prompt {
            session.draft = session.draft.isEmpty ? prompt : session.draft + "\n\n" + prompt
        }
        lastInteraction = Date()
        if !chatPresented { record("Command channel opened") }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { chatPresented = true }
        DispatchQueue.main.async { composerFocused = true }
    }

    private func enterIdle() {
        composerFocused = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { chatPresented = false }
        record("Returned to idle")
    }

    private func record(_ title: String) {
        events.append(WorkspaceEvent(title: title))
        if events.count > 40 { events.removeFirst(events.count - 40) }
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
                Button { workspaceMode = mode; if mode == .focus { openChat() } } label: {
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
            Button { openChat() } label: { Text("INTERRUPT  ⌘K").font(Console.mono(10)) }
                .buttonStyle(ConsoleButtonStyle()).padding(.trailing, 18)
            Circle().fill(telemetry.isNetworkAvailable ? Console.green : Console.amber).frame(width: 5, height: 5)
            Text(telemetry.pathStatus.uppercased()).font(Console.mono(9)).tracking(1).padding(.leading, 7).padding(.trailing, 20)
        }
        .background(Console.panel)
        .overlay(alignment: .top) { Rectangle().fill(Console.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Console.line).frame(height: 1) }
    }

    private var activityGraphPanel: some View {
        ConsolePanel(title: "OPENAI API STATUS", index: "01", status: "PUBLIC FEED / 60 SEC") {
            CircularActivityView(isActive: scenePhase == .active && !chatPresented)
                .background(ConsoleGrid())
        }
    }

    private var conversationPanel: some View {
        ConsolePanel(title: "COMMAND CHANNEL", index: "02", status: session.isSending ? "RUNNING" : "STANDBY") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Console.blue)
                    Text(session.settings.activeModel).foregroundStyle(Console.text).lineLimit(1)
                    if session.settings.provider == .chatGPT {
                        Link(session.codex.isSignedIn ? "Using ChatGPT plan" : "ChatGPT connection required",
                             destination: ChatGPTAccount.usageURL).foregroundStyle(Console.blue)
                    }
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
                    if session.messages.isEmpty && session.pendingMessage == nil && session.interruptedTurns.isEmpty {
                        ScrollView { emptyConversation }
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
                    ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                        ForEach(session.interruptedTurns.filter { $0.afterMessageCount == index }) { interrupted in
                            InterruptedTurnRow(turn: interrupted)
                        }
                        MessageRow(message: message)
                    }
                    ForEach(session.interruptedTurns.filter { $0.afterMessageCount >= session.messages.count }) { interrupted in
                        InterruptedTurnRow(turn: interrupted)
                    }
                    if let message = session.pendingMessage { MessageRow(message: message) }
                    if session.isSending {
                        if !session.partialReply.isEmpty {
                            MessageRow(message: ChatMessage(role: .assistant, content: session.partialReply))
                        }
                        if session.settings.provider == .chatGPT { CodexTaskView(runtime: session.codex) }
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(session.settings.provider == .chatGPT && !session.codex.prompts.isEmpty
                                 ? "Waiting for your input…"
                                 : session.partialReply.isEmpty ? "Awaiting model response…" : "Receiving response…").font(Console.mono(11)).foregroundStyle(Console.blue)
                            Spacer()
                        }
                    } else if session.settings.provider == .chatGPT { CodexTaskView(runtime: session.codex) }
                    Color.clear.frame(height: 1).id("conversation-bottom").accessibilityHidden(true)
                }.padding(18)
            }
            .accessibilityLabel("Conversation")
            .onAppear { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            .onChange(of: session.messages.count) { _ in scrollToBottom(proxy) }
            .onChange(of: session.pendingMessage?.id) { _ in scrollToBottom(proxy) }
            .onChange(of: session.partialReply) { _ in scrollToBottom(proxy) }
            .onChange(of: session.interruptedTurns.count) { _ in scrollToBottom(proxy) }
            .onChange(of: session.codex.prompts.count) { _ in scrollToBottom(proxy) }
            .onChange(of: session.codex.activity.count) { _ in scrollToBottom(proxy) }
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
            Text(session.isSending ? "MODEL REQUEST IN PROGRESS" : chatPresented ? "CHANNEL OPEN" : "IDLE / TYPE TO INTERRUPT").foregroundStyle(session.isSending ? Console.amber : Console.muted)
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

private struct InterruptedTurnRow: View {
    let turn: InterruptedTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MessageRow(message: turn.message)
            Text(turn.wasCancelled ? "STOPPED / INCOMPLETE" : "INTERRUPTED / INCOMPLETE")
                .font(Console.mono(10)).foregroundStyle(Console.amber)
            if let response = turn.response { MessageRow(message: response) }
            else { Text("No response text was received.").font(Console.mono(11)).foregroundStyle(Console.muted) }
        }
        .padding(10)
        .overlay(Rectangle().stroke(Console.amber.opacity(0.35)))
        .accessibilityElement(children: .contain).accessibilityLabel("Interrupted conversation attempt")
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
