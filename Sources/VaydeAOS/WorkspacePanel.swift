import SwiftUI
import VaydeAOSCore

/// The fox occupies the right third of the existing chat panel.
struct WorkspaceChatsPanel: View {
    @ObservedObject var session: ChatSession
    let animation: Namespace.ID
    let openChat: () -> Void
    let openPanel: () -> Void

    var body: some View {
        ConsolePanel(title: "WORKSPACE CHATS", index: "WS", status: "\(session.workspaceChats.count) SAVED") {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ScrollView(showsIndicators: false) {
                        chatList.padding(14)
                    }
                    .frame(width: geometry.size.width * 2 / 3)
                    ZStack {
                        if !session.workspaceConsole.panelExpanded {
                            WorkspacePanelLauncher(animation: animation, open: openPanel)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .leading) { Rectangle().fill(Console.line).frame(width: 1) }
                }
            }
            .frame(height: 132)
        }
    }

    private var chatList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { session.newChat(); openChat() } label: {
                    Label("NEW CHAT", systemImage: "square.and.pencil")
                }.buttonStyle(ConsoleButtonStyle()).disabled(!session.canOrganizeChats)
                Button(action: openChat) { Label("CONTINUE CHAT", systemImage: "arrow.up.right") }
                    .buttonStyle(ConsoleButtonStyle())
                Spacer(minLength: 0)
            }
            if let error = session.errorMessage {
                Text(error).font(Console.mono(10)).foregroundStyle(Console.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(session.workspaceChats.prefix(3)) { chat in
                Button {
                    session.selectChat(chat.id)
                    openChat()
                } label: {
                    HStack {
                        Text(chat.title).lineLimit(1)
                        Spacer()
                        Text(chat.draft.isEmpty ? "\(chat.messages.count) messages" : "Draft saved")
                            .foregroundStyle(Console.muted)
                    }.font(Console.mono(10)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(!session.canOrganizeChats)
            }
        }
    }
}

private struct WorkspacePanelLauncher: View {
    let animation: Namespace.ID
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Console.image("vayde-mark", extension: "png")
                    .resizable().scaledToFit().frame(width: 56, height: 56)
                    .matchedGeometryEffect(id: "workspace-panel-fox", in: animation)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("MODEL").foregroundStyle(Console.text)
                    Text("ACTIVITY").foregroundStyle(Console.blue)
                }.font(Console.mono(10, weight: .semibold)).tracking(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(Color.clear)
                    .matchedGeometryEffect(id: "workspace-panel-surface", in: animation)
            }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Console.blue.opacity(0.35), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open model activity")
        .accessibilityHint("Replace the workspace screen with model usage, workload, and reasoning")
    }
}

/// Replaces the selected workspace's dashboard while its widgets stay mounted behind it.
struct WorkspacePanel: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var telemetry: SystemTelemetry
    @Binding var showingConnectionSettings: Bool
    let animation: Namespace.ID
    let close: () -> Void

    private var usesRuntime: Bool { session.settings.provider == .chatGPT }
    private var latest: RequestPerformance? { session.performanceHistory.last }
    private var activeTools: [CodexActivity] {
        usesRuntime && session.isSending ? session.codex.activity.filter { $0.status == "inProgress" } : []
    }
    private var status: String {
        if usesRuntime && !session.codex.prompts.isEmpty { return "INPUT NEEDED" }
        if session.isSending { return "WORKING" }
        return session.errorMessage == nil ? "STANDBY" : "ATTENTION"
    }
    private var statusColor: Color {
        session.isSending || session.errorMessage != nil ? Console.amber : Console.green
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Console.image("vayde-mark", extension: "png")
                    .resizable().scaledToFit().frame(width: 66, height: 66)
                    .matchedGeometryEffect(id: "workspace-panel-fox", in: animation)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("MODEL ACTIVITY").font(Console.mono(10, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(Console.muted)
                    workspaceIdentity
                }
                Spacer(minLength: 12)
                Button(action: close) { Label("BACK TO WORKSPACE", systemImage: "arrow.left") }
                    .buttonStyle(ConsoleButtonStyle())
                    .accessibilityLabel("Back to workspace")
            }
            .padding(22)
            .background(Console.raised.opacity(0.3))
            Rectangle().fill(Console.line).frame(height: 1)
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    section("MODEL", symbol: "cpu") {
                        Text(session.modelSelection.displayName)
                            .font(Console.mono(15, weight: .medium)).foregroundStyle(Console.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(session.settings.connectionLabel)
                            .font(Console.mono(9)).foregroundStyle(Console.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        InstrumentRow(label: "STATE", value: status, color: statusColor)
                    }
                    section("MODEL USAGE", symbol: "chart.bar.xaxis") {
                        InstrumentRow(label: "INPUT TOKENS", value: tokens(latest?.inputTokens))
                        InstrumentRow(label: "OUTPUT TOKENS", value: tokens(latest?.outputTokens))
                        if !usesRuntime, let speed = latest?.outputTokensPerWallSecond {
                            InstrumentRow(label: "OUTPUT / WALL SEC", value: String(format: "%.1f tok/s", speed))
                        }
                        Text(usageCaption).font(Console.mono(8)).foregroundStyle(Console.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if usesRuntime {
                            Link("ACCOUNT PLAN USAGE", destination: ChatGPTAccount.usageURL)
                                .font(Console.mono(9)).foregroundStyle(Console.blue)
                        }
                    }
                    section("WORKLOAD", symbol: "waveform.path") {
                        InstrumentRow(label: "ACTIVE REQUESTS", value: session.isSending ? "1" : "0",
                                      color: statusColor)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            InstrumentRow(label: session.isSending ? "ELAPSED" : "LAST REQUEST",
                                          value: elapsed)
                        }
                        InstrumentRow(label: "RECENT REQUESTS", value: "\(session.performanceHistory.count)")
                        InstrumentRow(label: "WORKSPACE CHATS", value: "\(session.workspaceChats.count)")
                        if usesRuntime {
                            InstrumentRow(label: "ACTIVE TOOLS", value: "\(activeTools.count)")
                            ForEach(activeTools.prefix(3)) { activity in
                                Text(activity.title).font(Console.mono(9)).foregroundStyle(Console.blue)
                                    .lineLimit(2)
                            }
                        }
                        Text("Up to 60 requests since chat selection or connection change.")
                            .font(Console.mono(8)).foregroundStyle(Console.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    section("REASONING", symbol: "slider.horizontal.3") {
                        SessionReasoningControl(session: session)
                    }
                    section("HOST", symbol: "desktopcomputer") {
                        InstrumentRow(label: "CPU", value: telemetry.cpuSampleAvailable
                                      ? String(format: "%.1f%%", telemetry.cpuUsage * 100) : "Unavailable")
                        InstrumentRow(label: "MEMORY", value: Console.memory(telemetry.memoryUsedBytes))
                        InstrumentRow(label: "NETWORK", value: telemetry.pathStatus.uppercased())
                    }
                }
                .padding(22)
                HStack {
                    Text("MODEL / USAGE / WORKLOAD / REASONING")
                        .font(Console.mono(9)).foregroundStyle(Console.muted)
                    Spacer()
                    Button { showingConnectionSettings = true } label: {
                        Label("CONFIGURE UPLINK", systemImage: "arrow.up.right")
                    }.buttonStyle(ConsoleButtonStyle()).disabled(session.isSending)
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            Rectangle().fill(Console.panel)
                .matchedGeometryEffect(id: "workspace-panel-surface", in: animation)
        }
        .overlay(Rectangle().strokeBorder(Console.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model activity for \(session.selectedWorkspace.name)")
    }

    private var workspaceIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.selectedWorkspace.name.uppercased())
                .font(Console.mono(13, weight: .medium)).foregroundStyle(Console.blue)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.chats.first(where: { $0.id == session.selectedChatID })?.title ?? "New chat")
                .font(Console.mono(10)).foregroundStyle(Console.text).lineLimit(2)
            Text(session.workspaceDirectory.path).font(Console.mono(8)).foregroundStyle(Console.muted)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .help(session.workspaceDirectory.path)
        }
    }

    private var elapsed: String {
        if let start = session.performanceRequestStartedAt {
            return String(format: "%.0f s", max(0, ProcessInfo.processInfo.systemUptime - start))
        }
        return latest.map { String(format: "%.1f s", $0.elapsed) } ?? "—"
    }

    private var usageCaption: String {
        guard let latest else { return "No request measured for this chat yet." }
        if latest.inputTokens == nil && latest.outputTokens == nil {
            return "The provider did not report token usage for the last request."
        }
        return usesRuntime
            ? "Last runtime-reported model response in the completed request. — means unavailable."
            : "Provider-reported tokens for the last request. — means unavailable."
    }

    private func tokens(_ value: Int?) -> String { value.map { $0.formatted() } ?? "—" }

    private func section<Content: View>(_ title: String, symbol: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(Console.mono(9, weight: .semibold))
                .tracking(1).foregroundStyle(Console.blue)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Console.background.opacity(0.55))
        .overlay(Rectangle().strokeBorder(Console.line, lineWidth: 1))
    }
}
