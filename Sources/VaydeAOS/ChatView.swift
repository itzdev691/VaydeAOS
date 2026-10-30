import AppKit
import SwiftUI
import VaydeAOSCore

struct ChatView: View {
    @EnvironmentObject private var voice: VoiceAssistant
    @ObservedObject var session: ChatSession
    @ObservedObject var projectConsoles: ProjectConsoleRegistry
    @Binding var showingConnectionSettings: Bool
    @StateObject private var telemetry = SystemTelemetry()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceWindowVisible) private var workspaceWindowVisible
    @Environment(\.workspaceBootReady) private var bootReady
    @State private var bootStep = 0
    @FocusState private var composerFocused: Bool
    @State private var chatPresented = false
    @State private var channelWorkspaceID: UUID?
    @State private var channelChatID: UUID?
    @Namespace private var workspacePanelAnimation
    private var workspacePanelPresented: Bool { session.workspaceConsole.panelExpanded && !chatPresented }
    private var chatSidebarVisible: Bool { session.workspaceConsole.sidebarVisible }
    @State private var lastInteraction = Date()
    @State private var idlePresented = false
    @State private var resumeComposerFocus = false
    private let idleTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if idlePresented { idleHeader }
                else {
                    header.workspaceBoot(stage: 0, label: "DISPLAY")
                    navigation.workspaceBoot(stage: 1, label: "NAVIGATION")
                }
                HStack(alignment: .top, spacing: 12) {
                    if chatSidebarVisible {
                        ChatSidebar(session: session, openChat: { openChat(resuming: true) },
                                    openConsole: { openConsole() }, isChatOpen: chatPresented)
                            .frame(width: 208)
                            .workspaceBoot(stage: 2, label: "WORKSPACES")
                    }
                    ZStack {
                        ZStack {
                            ProjectConsoleView(session: session, telemetry: telemetry,
                                               controller: projectConsoles.console(for: session.selectedWorkspaceID),
                                               openChat: { openChat() }, openModelActivity: openWorkspacePanel)
                                .id(session.selectedWorkspaceID)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(chatPresented ? 0 : 1)
                                .allowsHitTesting(!chatPresented)
                                .accessibilityHidden(chatPresented)
                                .overlayPreferenceValue(AskVaydeBoundsKey.self) { anchor in
                                    GeometryReader { panelGeometry in
                                        let bounds = CGRect(origin: .zero, size: panelGeometry.size)
                                        let origin = anchor.map { panelGeometry[$0] } ?? bounds
                                        let frame = chatPresented ? bounds : origin
                                        chatChannel
                                            .frame(width: frame.width, height: frame.height)
                                            .clipped()
                                            .offset(x: frame.minX, y: frame.minY)
                                            .opacity(chatPresented ? 1 : 0)
                                            .allowsHitTesting(chatPresented)
                                            .disabled(!chatPresented)
                                            .accessibilityHidden(!chatPresented)
                                    }
                                }
                        }
                        .opacity(workspacePanelPresented ? 0 : 1)
                        .allowsHitTesting(!workspacePanelPresented)
                        .accessibilityHidden(workspacePanelPresented)
                        if workspacePanelPresented {
                            WorkspacePanel(session: session, telemetry: telemetry,
                                           showingConnectionSettings: $showingConnectionSettings,
                                           animation: workspacePanelAnimation, close: closeWorkspacePanel)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86),
                           value: session.workspaceConsole.panelExpanded)
                .opacity(idlePresented ? 0 : 1)
                .allowsHitTesting(!idlePresented)
                .accessibilityHidden(idlePresented)
                .overlay {
                    if workspaceWindowVisible {
                        IdleDashboardView(session: session, telemetry: telemetry,
                                          isActive: idlePresented && scenePhase == .active)
                            .opacity(idlePresented ? 1 : 0)
                            .allowsHitTesting(idlePresented)
                            .accessibilityHidden(!idlePresented)
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if idlePresented { idleFooter }
                else { footer.workspaceBoot(stage: 10, label: "STATUS BAR") }
            }
            .background {
                Console.background
                RadialGradient(colors: [Console.blueStrong.opacity(0.16), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 650)
                ConsoleGrid()
            }
        }
        .environment(\.workspaceBootStep, reduceMotion ? 11 : bootStep)
        .task(id: session.modelCatalogIdentity) { await session.refreshModels() }
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
        .background(WorkspaceInputMonitor(onActivity: { event in
            if idlePresented && event.type != .keyDown { return false }
            return registerInteraction()
        }))
        .background {
            Button("Interrupt") { openChat() }.keyboardShortcut("k", modifiers: .command).hidden()
        }
        .onExitCommand {
            if workspacePanelPresented {
                closeWorkspacePanel()
            } else if chatPresented {
                if session.isSending { session.stop() } else { openConsole() }
            }
        }
        .onReceive(idleTicker) { date in
            guard workspaceWindowVisible, bootReady, reduceMotion || bootStep == 11, scenePhase == .active,
                  !idlePresented, !showingConnectionSettings, NSApp.modalWindow == nil,
                  NSApp.keyWindow?.sheetParent == nil,
                  NSApp.keyWindow?.sheets.isEmpty == true, !session.isSending,
                  session.codex.prompts.isEmpty,
                  date.timeIntervalSince(lastInteraction) >= 15 else { return }
            resumeComposerFocus = composerFocused
            composerFocused = false
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { idlePresented = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaydeShowIdle)) { _ in
            guard !session.isSending, !showingConnectionSettings, session.codex.prompts.isEmpty else { return }
            resumeComposerFocus = composerFocused
            composerFocused = false
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { idlePresented = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaydeOpenChat)) { _ in openChat(resuming: true) }
        .onAppear {
            if workspaceWindowVisible && scenePhase != .background { telemetry.start() }
            if voice.isInteracting { openChat(resuming: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            closeChatChannel()
        }
        .onDisappear { closeChatChannel(); telemetry.stop() }
        .onChange(of: workspaceWindowVisible) { visible in
            if visible && scenePhase != .background { telemetry.start() } else { telemetry.stop() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background || !workspaceWindowVisible { telemetry.stop() } else { telemetry.start() }
            if phase == .active { _ = registerInteraction() }
        }
        .onChange(of: session.selectedWorkspaceID) { _ in
            if channelWorkspaceID != session.selectedWorkspaceID {
                closeChatChannel()
                composerFocused = false
                chatPresented = false
            }
            _ = registerInteraction()
        }
        .onChange(of: session.selectedChatID) { id in
            if chatPresented && channelWorkspaceID == session.selectedWorkspaceID { channelChatID = id }
        }
        .onChange(of: session.isSending) { sending in
            _ = registerInteraction()
            record(sending ? "Model request started" : "Model request finished")
            if !sending { openChat(resuming: true) }
        }
        .onChange(of: session.errorMessage) { error in
            if error != nil, channelWorkspaceID == session.selectedWorkspaceID {
                _ = registerInteraction()
                record("Model channel needs attention")
            }
        }
        .onChange(of: showingConnectionSettings) { showing in
            _ = registerInteraction()
            if !showing && chatPresented { composerFocused = true }
        }
    }

    /// Wake input dismisses the ambient screen before it can activate a hidden control.
    @discardableResult
    private func registerInteraction() -> Bool {
        lastInteraction = Date()
        guard idlePresented else { return false }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { idlePresented = false }
        if resumeComposerFocus && chatPresented { composerFocused = true }
        resumeComposerFocus = false
        return true
    }

    private var idleHeader: some View {
        HStack(spacing: 18) {
            Rectangle().fill(Console.red).frame(width: 2, height: 28)
            Console.image("vayde-mark", extension: "png").resizable().scaledToFit().frame(width: 26, height: 26)
            Text("VAYDE AOS").font(Console.mono(18, weight: .light)).tracking(3)
            Rectangle().fill(Console.blueBright).frame(width: 1, height: 23)
            Text("VAYDENET").font(Console.mono(12)).tracking(2).foregroundStyle(Console.blueBright)
            Spacer()
            Text(session.selectedWorkspace.name.uppercased()).font(Console.mono(12)).tracking(2)
                .foregroundStyle(Console.blueBright).lineLimit(1)
            Spacer()
            Button { _ = registerInteraction() } label: {
                Text("IDLE  —").font(Console.mono(10)).tracking(2).foregroundStyle(Console.blueBright)
            }.buttonStyle(.plain).accessibilityLabel("Resume workspace")
            Rectangle().fill(Console.red).frame(width: 2, height: 28)
        }.padding(.horizontal, 15).frame(height: 48).background(IdlePalette.background)
            .overlay(alignment: .bottom) { Rectangle().fill(Console.blue).frame(height: 0.6).padding(.horizontal, 15) }
    }

    private var idleFooter: some View {
        HStack {
            Rectangle().fill(Console.red).frame(width: 2, height: 26)
            Text("—  AMBIENT DISPLAY").tracking(2)
            Spacer()
            Button { _ = registerInteraction() } label: { Text("PRESS ANY KEY TO RESUME  —").tracking(2) }
                .buttonStyle(.plain)
            Rectangle().fill(Console.red).frame(width: 2, height: 26)
        }.font(Console.mono(9)).foregroundStyle(Console.blueBright).padding(.horizontal, 15).frame(height: 34)
            .background(Console.panel)
            .overlay(alignment: .top) { Rectangle().fill(Console.blue).frame(height: 0.6).padding(.horizontal, 15) }
    }

    private func openWorkspacePanel() {
        composerFocused = false
        _ = registerInteraction()
        session.updateWorkspaceConsole { $0.panelExpanded = true }
    }

    private func closeWorkspacePanel() {
        _ = registerInteraction()
        session.updateWorkspaceConsole { $0.panelExpanded = false }
    }

    private func openChat(prompt: String? = nil, resuming: Bool = false) {
        if !chatPresented || channelWorkspaceID != session.selectedWorkspaceID || resuming {
            session.prepareChatForOpening(resuming: resuming)
        }
        channelWorkspaceID = session.selectedWorkspaceID
        channelChatID = session.selectedChatID
        if let prompt {
            session.draft = session.draft.isEmpty ? prompt : session.draft + "\n\n" + prompt
        }
        _ = registerInteraction()
        if !chatPresented { record("Command channel opened") }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            if session.workspaceConsole.panelExpanded { closeWorkspacePanel() }
            chatPresented = true
        }
        DispatchQueue.main.async { composerFocused = true }
    }

    private func openConsole() {
        closeChatChannel()
        _ = registerInteraction()
        channelWorkspaceID = nil
        composerFocused = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            if session.workspaceConsole.panelExpanded { closeWorkspacePanel() }
            chatPresented = false
        }
        record("Workspace console opened")
    }

    private func closeChatChannel() {
        if let channelChatID { session.closeChatChannel(channelChatID) }
        channelChatID = nil
    }

    private func record(_ title: String) {
        session.updateWorkspaceConsole { $0.record(title) }
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
            VoiceAssistantButton(voice: voice)
            Button { showingConnectionSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15)).frame(width: 20, height: 20)
            }
            .buttonStyle(ConsoleButtonStyle()).padding(.leading, 12)
            .disabled(session.isSending).help("Connection settings (Command-comma)").accessibilityLabel("Connection settings")
        }
        .padding(.horizontal, 22).frame(height: 66)
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            Button { openConsole() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").foregroundStyle(Console.muted)
                    Text("CONSOLE").tracking(1.5)
                }
                .font(Console.mono(10, weight: .medium)).padding(.horizontal, 20)
                .frame(height: 38)
                .foregroundStyle(chatPresented ? Console.muted : Console.blue)
                .background(chatPresented ? .clear : Console.blue.opacity(0.07))
                .overlay(alignment: .bottom) {
                    if !chatPresented { Rectangle().fill(Console.red).frame(height: 2) }
                }
            }
            .buttonStyle(.plain).accessibilityAddTraits(chatPresented ? [] : .isSelected)
            Spacer()
            if !chatSidebarVisible {
                Button {
                    session.updateWorkspaceConsole { $0.sidebarVisible = true }
                } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(ConsoleButtonStyle()).help("Show workspaces")
            }
            ChatWorkspacePicker(session: session, openConsole: { openConsole() }).padding(.horizontal, 12)
            Button { openChat() } label: { Text("OPEN CHAT  ⌘K").font(Console.mono(10)) }
                .buttonStyle(ConsoleButtonStyle()).padding(.trailing, 18)
            Circle().fill(telemetry.isNetworkAvailable ? Console.green : Console.amber).frame(width: 5, height: 5)
            Text(telemetry.pathStatus.uppercased()).font(Console.mono(9)).tracking(1).padding(.leading, 7)
            Text("VAYDENET").font(Console.mono(10, weight: .semibold)).tracking(1.5)
                .foregroundStyle(Console.blue).padding(.horizontal, 20)
        }
        .background(Console.panel)
        .overlay(alignment: .top) { Rectangle().fill(Console.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Console.line).frame(height: 1) }
    }

    private var conversationPanel: some View {
        ConsolePanel(title: "COMMAND CHANNEL", index: "02", status: session.isSending ? "RUNNING" : "STANDBY") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Console.blue)
                    Text(session.modelSelection.displayName).foregroundStyle(Console.text).lineLimit(1)
                    if session.settings.provider == .chatGPT {
                        Link(session.codex.isSignedIn ? "Using ChatGPT plan" : "ChatGPT connection required",
                             destination: ChatGPTAccount.usageURL).foregroundStyle(Console.blue)
                    }
                    Text("/ \(session.messages.count) messages").foregroundStyle(Console.muted)
                    Spacer()
                    Button { session.newChat(); composerFocused = true } label: {
                        Label("NEW CHAT", systemImage: "plus")
                    }
                    .buttonStyle(.plain).foregroundStyle(Console.blue).disabled(!session.canOrganizeChats).help("New chat (Command-N)").accessibilityLabel("New chat")
                }
                .font(Console.mono(10)).padding(.horizontal, 16).frame(height: 38)
                .background(Console.background.opacity(0.45))
                Group {
                    if session.messages.isEmpty && session.pendingMessage == nil && session.interruptedTurns.isEmpty {
                        GeometryReader { geometry in
                            ScrollView {
                                emptyConversation
                                    .frame(minHeight: geometry.size.height)
                            }
                        }
                    } else { transcript }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                composer
            }
            .background(Console.chatBackground)
        }
    }

    private var chatChannel: some View {
        VStack(spacing: 8) {
            HStack {
                Circle().fill(Console.green).frame(width: 5, height: 5)
                Button { session.updateWorkspaceConsole { $0.sidebarVisible.toggle() } } label: {
                    Image(systemName: "sidebar.left")
                }.buttonStyle(.plain).accessibilityLabel("Toggle chat sidebar")
                Text("CHANNEL OPEN").tracking(1.2)
                Text(session.workspaceDirectory.lastPathComponent).foregroundStyle(Console.muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { openConsole() } label: {
                    Label("CLOSE CHAT", systemImage: "xmark")
                }.buttonStyle(ConsoleButtonStyle())
                    .help("Keep the conversation and draft; return to the console")
            }.font(Console.mono(9)).foregroundStyle(Console.blue)
            conversationPanel
        }
        .background(Console.chatBackground)
    }

    private var emptyConversation: some View {
        VStack(spacing: 14) {
            Text("Ask Vayde")
                .font(.system(size: 30, weight: .light, design: .rounded))
                .foregroundStyle(Console.text)
            Text("Intent becomes action.")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(Console.text)
            Text("A direct line to your model. Start with a question,\nan idea, or the next thing you want to build.")
                .font(.system(size: 13)).foregroundStyle(Console.muted).lineSpacing(5)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { conversationPrompts }
                VStack(spacing: 7) { conversationPrompts }
            }.padding(.top, 5)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var conversationPrompts: some View {
        promptButton("Explore an idea", prompt: "Help me explore an idea. Start by asking what I want to build.")
        promptButton("Break down a task", prompt: "Help me break a task into clear, practical steps.")
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
            .onChange(of: session.selectedChatID) { _ in scrollToBottom(proxy) }
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
            ChatModelControls(session: session) { showingConnectionSettings = true }
            if let transition = session.contextTransitionNotice {
                Text(transition).font(Console.mono(10)).foregroundStyle(Console.amber)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel("Runtime context change: " + transition)
            }
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
                ChatWorkspacePicker(session: session)
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
        .padding(12).background(Console.chatComposer)
        .overlay(Rectangle().strokeBorder(composerFocused ? Console.red.opacity(0.55) : Console.line, lineWidth: 1))
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Console.blue).frame(width: 4, height: 4)
            Text("VAYDE AOS").tracking(1)
            Text("/  NATIVE CONSOLE").foregroundStyle(Console.muted)
            Spacer()
            if !chatPresented && !idlePresented { Text("LOCAL / OBSERVED DATA").foregroundStyle(Console.muted) }
            Text(session.isSending ? "MODEL REQUEST IN PROGRESS" : idlePresented ? "IDLE" : chatPresented ? "CHANNEL OPEN" : "CONSOLE / ⌘K TO CHAT").foregroundStyle(session.isSending ? Console.amber : Console.muted)
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
