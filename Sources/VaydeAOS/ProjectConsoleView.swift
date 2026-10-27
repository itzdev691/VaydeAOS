import SwiftUI
import VaydeAOSCore

/// The chat overlay grows from this tile without participating in the console layout.
struct AskVaydeBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Repository, serial, build, and host observations share the workspace with chat and notes.
struct ProjectConsoleView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var telemetry: SystemTelemetry
    @ObservedObject var controller: ProjectConsoleController
    let openChat: () -> Void
    let openModelActivity: () -> Void
    @State private var selectedTab = "PACKET INSPECTOR"
    @State private var transport = "All transports"
    @State private var eventFilter = "All events"
    @State private var configuringBuild = false
    @State private var commandDraft = ""
    @State private var editingNotes = false
    @State private var followingOutput = true
    @State private var projectError: String?
    @FocusState private var notesFocused: Bool
    private let refreshTicker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var filteredPackets: [WorkspacePacket] {
        controller.packets.filter { transport == "All transports" || $0.transport == transport }
    }
    private var filteredEvents: [ConsoleEvent] {
        controller.events.filter { eventFilter == "All events" || $0.warning }
    }
    private var receivedPackets: Int { controller.packets.filter(\.deliveryConfirmed).count }
    private var isStudentDB: Bool {
        StudentDBWorkspace.matches(name: session.selectedWorkspace.name, directory: session.workspaceDirectory.path)
    }
    private var studentTab: String { session.workspaceConsole.studentDB.selectedTab }
    private var jobsRunning: Bool { controller.buildRunning || controller.programRunning }
    private var projectDirectory: String {
        if session.workspaceConsole.projectDirectory != nil { return session.workspaceDirectory.path }
        if isStudentDB, session.selectedWorkspace.directory.isEmpty {
            let checkout = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("StudentDB(deploy)").path
            if FileManager.default.fileExists(atPath: checkout + "/CMakeLists.txt") { return checkout }
        }
        if !session.selectedWorkspace.directory.isEmpty { return session.workspaceDirectory.path }
        // A workspace name may resolve a sibling checkout. It never changes chat storage.
        let sibling = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(session.selectedWorkspace.name).path
        if FileManager.default.fileExists(atPath: sibling + "/.git") { return sibling }
        return session.workspaceDirectory.path
    }
    private var buildState: String {
        if controller.buildRunning { return "BUILDING" }
        guard let code = controller.buildExitCode else { return "NOT RUN" }
        return code == 0 ? "PASSED" : "FAILED"
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, max(0.78, (geometry.size.height - 40) / 792))
            let workbenchHeight = isStudentDB
                ? max(236 * scale, 35 + CGFloat(StudentDBWorkspace.sources.count) * 27 + 1)
                : 236 * scale
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    projectState.frame(height: 98 * scale)
                    currentWork.frame(height: 86 * scale)
                    HStack(alignment: .top, spacing: 10) {
                        Group { if isStudentDB { studentSources } else { deviceBench } }.frame(maxWidth: .infinity)
                        Group { if isStudentDB { studentWorkbench } else { transportReadiness } }.frame(width: geometry.size.width * 0.295)
                        askVayde.frame(width: geometry.size.width * 0.23)
                            .anchorPreference(key: AskVaydeBoundsKey.self, value: .bounds) { $0 }
                    }.frame(height: workbenchHeight)
                    Group { if isStudentDB { studentInspector } else { packetInspector } }.frame(height: 212 * scale)
                    HStack(alignment: .top, spacing: 10) {
                        buildVerification.frame(maxWidth: .infinity)
                        developmentEvents.frame(width: geometry.size.width * 0.295)
                        scratchpad.frame(width: geometry.size.width * 0.225)
                    }.frame(height: 160 * scale)
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .font(Console.mono(10))
        .sheet(isPresented: $configuringBuild) { buildConfiguration }
        .onChange(of: editingNotes) { notesFocused = $0 }
        .onChange(of: session.canOrganizeChats) { ready in
            if ready { bindProjectIfNeeded() }
        }
        .task(id: projectDirectory) {
            bindProjectIfNeeded()
            controller.configure(directory: projectDirectory, command: session.workspaceConsole.buildCommand ?? (isStudentDB ? StudentDBWorkspace.buildCommand : nil), studentDB: isStudentDB)
            if isStudentDB { controller.selectSource(session.workspaceConsole.studentDB.sourcePath) }
            await controller.refresh()
        }
        .onReceive(refreshTicker) { _ in Task { await controller.refresh() } }
    }

    private var projectState: some View {
        BenchPanel("PROJECT STATE", index: "01", caption: "LOCAL / AUTO REFRESH 5S") {
            compactButton("PROJECT", symbol: "folder") { chooseProject() }.disabled(jobsRunning || !session.canOrganizeChats)
        } content: {
            HStack(spacing: 0) {
                projectMetric("archivebox", title: "REPOSITORY", value: controller.snapshot?.repository ?? session.selectedWorkspace.name,
                              detail: controller.directory)
                metricDivider
                projectMetric("point.topleft.down.to.point.bottomright.curvepath", title: "BRANCH",
                              value: controller.snapshot?.branch ?? "Reading…",
                              detail: controller.snapshot.map { "\($0.changedFiles) changed files" } ?? "")
                metricDivider
                projectMetric("circle.and.line.horizontal", title: "COMMIT", value: controller.snapshot?.commit ?? "—",
                              detail: controller.snapshot?.commitDate ?? "")
                metricDivider
                projectMetric("cpu", title: "BUILD TARGET", value: controller.snapshot?.target ?? "Reading…", detail: buildState)
            }.padding(.horizontal, 4).frame(maxHeight: .infinity)
        }
    }

    private var metricDivider: some View {
        Rectangle().fill(Console.blue.opacity(0.6)).frame(width: 1, height: 46)
    }

    private func projectMetric(_ symbol: String, title: String, value: String, detail: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(Console.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Console.mono(9, weight: .medium)).tracking(0.7).foregroundStyle(Console.muted)
                Text(value).font(Console.mono(13, weight: .medium)).foregroundStyle(Console.text).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(Console.mono(10)).foregroundStyle(Console.muted).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentWork: some View {
        BenchPanel("CURRENT WORK", index: "02") {
            HStack(spacing: 20) {
                Image(systemName: "target").font(.system(size: 27, weight: .light)).foregroundStyle(Console.blue)
                VStack(alignment: .leading, spacing: 5) {
                    metricLabel("WORKSPACE OBJECTIVE")
                    Text(session.messages.last(where: { $0.role == .user })?.content ?? "Open chat to define the next task.")
                        .lineLimit(2).help(session.messages.last(where: { $0.role == .user })?.content ?? "")
                }.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Console.blue.opacity(0.6)).frame(width: 1, height: 34)
                Image(systemName: controller.issue == nil ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.system(size: 27, weight: .light)).foregroundStyle(controller.issue == nil ? Console.blue : Console.red)
                VStack(alignment: .leading, spacing: 5) {
                    metricLabel(controller.issue == nil ? "WORKING TREE" : "ATTENTION")
                    Text(projectError ?? controller.issue ?? controller.snapshot.map { $0.isRepository ? "\($0.changedFiles) changed files · \($0.branch)" : "Select a repository with PROJECT." } ?? "Reading local project…").lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 26).frame(maxHeight: .infinity)
        }
    }

    private var deviceBench: some View {
        BenchPanel("DEVICE BENCH", index: "03", caption: "\(controller.devices.count) USB PORTS") {
            Menu {
                Picker("Baud rate", selection: $controller.baud) {
                    ForEach([9600, 57600, 115200, 230400, 460800, 921600], id: \.self) { Text("\($0) baud").tag($0) }
                }
            } label: { Text("\(controller.baud) ▾").font(Console.mono(9)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(controller.connectedPort != nil)
        } content: {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        tableHeading("DEVICE / PORT").frame(maxWidth: .infinity, alignment: .leading)
                        tableHeading("STATUS").frame(width: 83, alignment: .leading)
                        tableHeading("ACTIONS").frame(width: 66, alignment: .leading)
                    }.padding(.horizontal, 15).frame(height: 34).benchRule()
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(controller.devices) { device in
                                deviceRow(device).frame(height: 55).benchRule()
                            }
                            if controller.devices.isEmpty {
                                emptyState("No USB serial devices detected", detail: "Connect a USB board. Ports refresh every 5 seconds.", symbol: "cable.connector")
                                    .frame(minHeight: geometry.size.height - 34)
                            }
                        }
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: ConsoleDevice) -> some View {
        let connected = controller.connectedPort == device.port
        return HStack(spacing: 10) {
            Image(systemName: "cpu").font(.system(size: 22, weight: .light)).foregroundStyle(Console.blue)
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(device.port).font(Console.mono(9)).foregroundStyle(Console.muted).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading).help(device.port)
            status(connected ? "OPEN" : "DETECTED", color: connected ? Console.green : Console.blue)
                .frame(width: 83, alignment: .leading)
            compactButton(connected ? "CLOSE" : "SERIAL") {
                controller.connect(device)
                selectedTab = "SERIAL CONSOLE"
            }.frame(width: 66).accessibilityLabel("\(connected ? "Close" : "Open") serial port \(device.name)")
        }.padding(.horizontal, 15)
    }

    private var transportReadiness: some View {
        BenchPanel("TRANSPORT READINESS", index: "04", caption: "OBSERVED") {
            transportRow("network", "HOST NETWORK", value: telemetry.pathStatus,
                         detail: "\(telemetry.primaryInterfaceName ?? "—") · ↓ \(Console.rate(telemetry.receiveBytesPerSecond))\n↑ \(Console.rate(telemetry.sendBytesPerSecond))", color: telemetry.isNetworkAvailable ? Console.green : Console.amber)
            transportRow("cable.connector", "SERIAL", value: controller.connectedPort == nil ? "CLOSED" : "OPEN",
                         detail: controller.lastSerialAt.map { "Last data \($0.formatted(date: .omitted, time: .standard))" } ?? "No data received",
                         color: controller.connectedPort == nil ? Console.muted : Console.green)
            transportRow("antenna.radiowaves.left.and.right", "RADIO / PEER", value: controller.packets.isEmpty ? "UNVERIFIED" : "OBSERVED",
                         detail: "\(controller.packets.count) decoded messages\nSerial reports only", color: controller.packets.isEmpty ? Console.amber : Console.blue)
        }
    }

    private func transportRow(_ symbol: String, _ title: String, value: String, detail: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 23, weight: .light)).foregroundStyle(Console.blue).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                metricLabel(title)
                Text(detail).font(Console.mono(9)).foregroundStyle(Console.muted).lineSpacing(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            status(value, color: color)
        }.padding(.horizontal, 13).frame(maxHeight: .infinity).benchRule()
    }

    private var askVayde: some View {
        BenchPanel("Ask Vayde", index: "05") {
            Button(action: openChat) {
                VStack(spacing: 12) {
                    Console.image("vayde-mark", extension: "png").resizable().scaledToFit()
                        .frame(width: 64, height: 64).accessibilityHidden(true)
                    (Text("Ask ").foregroundColor(Console.white) + Text("Vayde").foregroundColor(Console.blue))
                        .font(.custom("AvenirNext-DemiBold", size: 30)).tracking(-0.7)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("GET ANSWERS. BUILD FASTER.").font(Console.mono(8)).tracking(1.4).foregroundStyle(Console.muted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ConsoleGrid())
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).accessibilityLabel("Ask Vayde: open workspace chat")
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Console.blue.opacity(0.5)))
                .padding(4)
                .contextMenu {
                    Button("Model activity", action: openModelActivity)
                }
        }
    }

    private var packetInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("06").foregroundStyle(Console.red).font(Console.mono(11, weight: .semibold)).padding(.horizontal, 12)
                inspectorTab("PACKET INSPECTOR")
                inspectorTab("SERIAL CONSOLE")
                inspectorTab("BUILD OUTPUT")
                Spacer(minLength: 6)
                if selectedTab == "PACKET INSPECTOR" {
                    compactButton(controller.paused ? "RESUME" : "PAUSE", symbol: controller.paused ? "play" : "pause") { controller.paused.toggle() }
                        .padding(.trailing, 10)
                } else {
                    compactButton(followingOutput ? "FOLLOWING" : "FOLLOW", symbol: "arrow.down.to.line") {
                        followingOutput.toggle()
                    }.padding(.trailing, 10)
                }
                compactButton("CLEAR", symbol: "trash") {
                    switch selectedTab {
                    case "PACKET INSPECTOR": controller.clearPackets()
                    case "SERIAL CONSOLE": controller.clearSerial()
                    default: controller.clearBuild()
                    }
                }.padding(.trailing, 10)
                if selectedTab == "PACKET INSPECTOR" {
                    Menu {
                        Picker("Transport", selection: $transport) {
                            ForEach(["All transports"] + Array(Set(controller.packets.map(\.transport))).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    } label: { HStack { Text(transport.uppercased()); Image(systemName: "chevron.down") } }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .font(Console.mono(9)).foregroundStyle(Console.blue).padding(.horizontal, 10)
                }
                status(controller.paused && selectedTab == "PACKET INSPECTOR" ? "PAUSED" : controller.connectedPort != nil || controller.buildRunning ? "LIVE" : "IDLE",
                       color: controller.paused ? Console.amber : Console.green).padding(.horizontal, 12)
            }.frame(height: 38).background(Console.raised.opacity(0.35)).benchRule()
            if selectedTab == "PACKET INSPECTOR" { packetTable }
            else { outputConsole }
        }.benchSurface()
    }

    private func inspectorTab(_ title: String) -> some View {
        Button { selectedTab = title } label: {
            Text(title).tracking(0.6).font(Console.mono(9, weight: .medium))
                .foregroundStyle(selectedTab == title ? Console.white : Console.muted)
                .padding(.horizontal, 12).frame(height: 38)
                .background(selectedTab == title ? Console.blue.opacity(0.14) : .clear)
                .overlay(alignment: .bottom) {
                    if selectedTab == title { Rectangle().fill(Console.red).frame(height: 2) }
                }
                .overlay(alignment: .trailing) { Rectangle().fill(Console.line).frame(width: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selectedTab == title ? .isSelected : [])
    }

    private var packetTable: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 36, 1)
            VStack(spacing: 0) {
                packetColumns(width: width, values: ["TIME", "DIRECTION", "TRANSPORT", "SENDER", "SEQUENCE", "RESULT", "INFO"], heading: true)
                    .frame(height: 28).benchRule()
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredPackets) { packet in
                            packetColumns(width: width, values: [packet.date.formatted(date: .omitted, time: .standard), packet.direction == "TX" ? "→" : packet.direction == "RX" ? "←" : "—", packet.transport, packet.sender,
                                                                packet.sequence, packet.result, packet.info], heading: false)
                                .frame(height: 23).benchRule()
                        }
                        if filteredPackets.isEmpty {
                            emptyState("Waiting for device packet reports", detail: "Open a serial port. VaydeNet delivery logs and JSON packet records appear here.", symbol: "waveform.path")
                                .frame(minHeight: 120)
                        }
                    }
                }
            }.padding(.horizontal, 9)
        }
    }

    private func packetColumns(width: CGFloat, values: [String], heading: Bool) -> some View {
        let fractions: [CGFloat] = [0.11, 0.095, 0.10, 0.175, 0.105, 0.11, 0.305]
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                Group {
                    if !heading && index == 5 {
                        status(values[index], color: ["OK", "RECEIVED"].contains(values[index]) ? Console.green : values[index] == "RETRY" ? Console.amber : Console.blue)
                    } else {
                        Text(values[index]).font(Console.mono(heading ? 9 : 10))
                            .foregroundStyle(heading ? Console.text : Console.muted)
                    }
                }.lineLimit(1).frame(width: width * fractions[index], alignment: .leading)
            }
        }.padding(.horizontal, 10)
    }

    private var outputConsole: some View {
        let lines = selectedTab == "BUILD OUTPUT" ? controller.buildLines : controller.serialLines
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if lines.isEmpty {
                        Text(selectedTab == "BUILD OUTPUT" ? "Run a build to stream its output here." : "Open SERIAL on a detected device to read its output.")
                            .foregroundStyle(Console.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Console.mono(11)).lineSpacing(3)
                            .foregroundStyle(Console.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("output-end")
                }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: lines.last) { _ in
                if followingOutput { proxy.scrollTo("output-end", anchor: .bottom) }
            }
            .onChange(of: followingOutput) { follow in
                if follow { proxy.scrollTo("output-end", anchor: .bottom) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var buildVerification: some View {
        BenchPanel(isStudentDB ? "BUILD & RUN" : "BUILD & VERIFICATION", index: "07") {
            HStack(spacing: 6) {
                compactButton(controller.buildRunning ? "BUILDING" : isStudentDB ? "BUILD" : "RUN BUILD", symbol: "play") {
                    selectedTab = "BUILD OUTPUT"
                    if isStudentDB { selectStudentTab("BUILD OUTPUT") }
                    if controller.command.isEmpty { editBuildCommand() }
                    else { controller.runBuild() }
                }.disabled(jobsRunning).accessibilityLabel(isStudentDB ? "Run StudentDB CMake build" : "Run build")
                compactButton("SETUP", symbol: "slider.horizontal.3") { editBuildCommand() }.disabled(jobsRunning)
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 0) {
                    buildStage(isStudentDB ? "CMake build" : "Built / tested", detail: controller.buildFinishedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? buildState,
                               complete: controller.buildExitCode == 0, connector: true)
                    if isStudentDB {
                        buildStage("CLI session", detail: controller.programRunning ? "running" : controller.programExitCode.map { "exit \($0)" } ?? "not run",
                                   complete: controller.programExitCode == 0, connector: true)
                        buildStage("Record file", detail: controller.recordBytes.map { "\($0) bytes · on disk" } ?? "not found",
                                   complete: controller.recordBytes != nil, connector: false)
                    } else {
                        buildStage("Serial open", detail: controller.connectedPort == nil ? "not connected" : "\(controller.baud) baud",
                                   complete: controller.connectedPort != nil, connector: true)
                        buildStage("Peer received", detail: receivedPackets == 0 ? "unverified" : "\(receivedPackets) reports",
                                   complete: receivedPackets > 0, connector: false)
                    }
                }
                Text(controller.command.isEmpty ? "SETUP selects a project build or test command." : "$ \(controller.command)")
                    .font(Console.mono(8)).foregroundStyle(Console.muted).lineLimit(1).truncationMode(.middle).help(controller.command)
            }.padding(.horizontal, 24).padding(.top, 12).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func buildStage(_ title: String, detail: String, complete: Bool, connector: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: complete ? "checkmark.circle" : "circle.dotted")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(complete ? Console.green : Console.blue)
                Rectangle().fill(connector ? Console.blue.opacity(0.7) : .clear).frame(height: 1)
            }
            Text(title).font(Console.mono(10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            Text(detail).font(Console.mono(9)).foregroundStyle(Console.muted).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var developmentEvents: some View {
        BenchPanel("DEVELOPMENT EVENTS", index: "08") {
            Menu {
                Picker("Event filter", selection: $eventFilter) {
                    Text("All events").tag("All events")
                    Text("Warnings").tag("Warnings")
                }
            } label: { HStack { Text(eventFilter); Image(systemName: "chevron.down") } }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .font(.system(size: 10)).foregroundStyle(Console.blue).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Console.line))
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredEvents) { event in
                        HStack(spacing: 8) {
                            Circle().fill(event.warning ? Console.red : Console.blue).frame(width: 5, height: 5)
                            Text(event.date.formatted(date: .omitted, time: .standard)).foregroundStyle(Console.muted)
                            Text(event.title).lineLimit(1).help(event.title)
                        }.font(Console.mono(9))
                    }
                    if filteredEvents.isEmpty { Text("No warnings recorded").foregroundStyle(Console.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(maxHeight: .infinity)
        }
    }

    private var scratchpad: some View {
        BenchPanel(isStudentDB ? "LEARNING NOTES" : "SCRATCHPAD") {
            compactButton(editingNotes ? "DONE" : "EDIT") { editingNotes.toggle() }
        } content: {
            ZStack(alignment: .topLeading) {
                if editingNotes {
                    TextEditor(text: Binding(get: { session.workspaceConsole.scratchpad }, set: { value in
                        session.updateWorkspaceConsole { $0.scratchpad = value }
                    })).font(Console.mono(10)).scrollContentBackground(.hidden).focused($notesFocused)
                        .accessibilityLabel("Workspace scratchpad").padding(7)
                } else {
                    ScrollView {
                        Text(session.workspaceConsole.scratchpad.isEmpty ? "Capture a note, idea, or test result…" : session.workspaceConsole.scratchpad)
                            .font(Console.mono(9)).foregroundStyle(Console.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Console.line)).padding(5)
        }
    }

    private var buildConfiguration: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("WORKSPACE BUILD COMMAND").font(Console.mono(15, weight: .medium)).foregroundStyle(Console.blue)
            Text(controller.directory).font(Console.mono(10)).foregroundStyle(Console.muted).textSelection(.enabled)
            TextField("Build or test command", text: $commandDraft).font(Console.mono(12)).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Build command")
            Text("Runs in the project directory through your login shell. Output remains in this console.")
                .font(Console.mono(10)).foregroundStyle(Console.muted)
            HStack {
                Spacer()
                Button("Cancel") { configuringBuild = false }.keyboardShortcut(.cancelAction)
                Button("Save command") {
                    controller.command = commandDraft
                    session.updateWorkspaceConsole { $0.buildCommand = commandDraft }
                    configuringBuild = false
                }.keyboardShortcut(.defaultAction).disabled(commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 500).background(Console.panel).preferredColorScheme(.dark)
    }

    private func editBuildCommand() { commandDraft = controller.command; configuringBuild = true }
    private func bindProjectIfNeeded() {
        guard session.workspaceConsole.projectDirectory == nil,
              projectDirectory != session.workspaceDirectory.path, session.canOrganizeChats else { return }
        do { try session.selectWorkspaceProject(projectDirectory); projectError = nil }
        catch { projectError = error.localizedDescription }
    }
    private func chooseProject() {
        guard let directory = controller.chooseDirectory() else { return }
        do { try session.selectWorkspaceProject(directory); projectError = nil }
        catch { projectError = error.localizedDescription }
    }
    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 23, weight: .light)).foregroundStyle(Console.blue.opacity(0.7))
            Text(title).font(Console.mono(11)).foregroundStyle(Console.text)
            Text(detail).font(Console.mono(9)).foregroundStyle(Console.muted).multilineTextAlignment(.center)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func metricLabel(_ title: String) -> some View {
        Text(title).font(Console.mono(9, weight: .medium)).tracking(1).foregroundStyle(Console.muted)
    }
    private func tableHeading(_ title: String) -> some View {
        Text(title).font(Console.mono(8)).tracking(0.5).foregroundStyle(Console.muted).lineLimit(1)
    }
    private func status(_ title: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).font(Console.mono(9, weight: .medium)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
    private func compactButton(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
                Text(title).font(Console.mono(9, weight: .medium)).lineLimit(1)
            }.frame(height: 27)
                .contentShape(Rectangle())
        }.buttonStyle(ConsoleButtonStyle(compact: true))
    }
}


private extension ProjectConsoleView {
    func selectStudentTab(_ tab: String) {
        session.updateWorkspaceConsole { $0.studentDB.selectedTab = tab }
    }

    var studentSources: some View {
        BenchPanel("SOURCE MAP", index: "03", caption: "C++ / LOCAL FILES") {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(StudentDBWorkspace.sources) { source in
                        Button {
                            controller.selectSource(source.path)
                            session.updateWorkspaceConsole {
                                $0.studentDB.sourcePath = source.path
                                $0.studentDB.selectedTab = "SOURCE TRACE"
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text").foregroundStyle(Console.blue)
                                Text(source.title).foregroundStyle(Console.text)
                                Spacer(minLength: 4)
                                Text(source.path).foregroundStyle(Console.muted).lineLimit(1).truncationMode(.middle)
                            }.font(Console.mono(9)).padding(.horizontal, 12).frame(height: 27)
                                .background(controller.sourcePath == source.path ? Console.blue.opacity(0.14) : .clear)
                                .benchRule().contentShape(Rectangle())
                        }.buttonStyle(.plain).help(source.detail)
                    }
                }
            }
        }
    }

    var studentWorkbench: some View {
        BenchPanel("C++ WORKBENCH", index: "04") {
            VStack(alignment: .leading, spacing: 0) {
                studentWorkRow("terminal", title: "CLI ENROLLMENT / LOGIN", detail: "Run, enter input, inspect the result.") {
                    selectStudentTab("CLI SESSION")
                }
                studentWorkRow("doc.text.magnifyingglass", title: "RECORD OUTPUT", detail: controller.recordBytes.map { "students.txt · \($0) bytes" } ?? "students.txt · not found") {
                    let file = URL(fileURLWithPath: controller.directory).appendingPathComponent("students.txt")
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()])
                }
                studentWorkRow("book.closed", title: "C++ LEARNING CONTEXT", detail: "Scope · references · headers · linking") {
                    openStudentNote("02 StudentDB C++ Learning Context")
                }
            }
        }
    }

    func studentWorkRow(_ symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(Console.blue).frame(width: 26)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(Console.mono(9, weight: .medium)).foregroundStyle(Console.text)
                    Text(detail).font(Console.mono(9)).foregroundStyle(Console.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").foregroundStyle(Console.blue)
            }.padding(.horizontal, 13).frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle()).benchRule()
        }.buttonStyle(.plain)
    }

    func openStudentNote(_ name: String) {
        var url = URLComponents()
        url.scheme = "obsidian"; url.host = "open"
        url.queryItems = [URLQueryItem(name: "vault", value: "VaydeNetV"), URLQueryItem(name: "file", value: "StudentDB/" + name)]
        if let destination = url.url { NSWorkspace.shared.open(destination) }
    }

    var studentInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("06").foregroundStyle(Console.red).font(Console.mono(11, weight: .semibold)).padding(.horizontal, 12)
                ForEach(["SOURCE TRACE", "CLI SESSION", "BUILD OUTPUT"], id: \.self) { tab in
                    Button { selectStudentTab(tab) } label: {
                        Text(tab).font(Console.mono(9, weight: .medium)).padding(.horizontal, 12).frame(height: 38)
                            .foregroundStyle(studentTab == tab ? Console.white : Console.muted)
                            .background(studentTab == tab ? Console.blue.opacity(0.14) : .clear)
                            .overlay(alignment: .bottom) {
                                if studentTab == tab { Rectangle().fill(Console.red).frame(height: 2) }
                            }
                    }.buttonStyle(.plain).accessibilityAddTraits(studentTab == tab ? .isSelected : [])
                }
                Spacer(minLength: 4)
                if studentTab == "SOURCE TRACE" {
                    compactButton("OPEN", symbol: "arrow.up.right") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: controller.directory).appendingPathComponent(controller.sourcePath))
                    }.disabled(controller.sourceText == nil)
                } else if studentTab == "CLI SESSION" {
                    compactButton(controller.programRunning ? "STOP" : "RUN CLI", symbol: controller.programRunning ? "stop" : "play") {
                        if controller.programRunning { controller.stopProgram() } else { controller.runProgram() }
                    }.disabled(controller.buildRunning)
                    compactButton("CLEAR") { controller.clearProgram() }.padding(.leading, 8)
                } else {
                    compactButton("CLEAR") { controller.clearBuild() }
                }
            }.padding(.trailing, 12).frame(height: 38).background(Console.raised.opacity(0.35)).benchRule()
            if studentTab == "SOURCE TRACE" {
                VStack(alignment: .leading, spacing: 0) {
                    Text(StudentDBWorkspace.sources.first(where: { $0.path == controller.sourcePath })?.detail ?? controller.sourcePath)
                        .font(Console.mono(9)).foregroundStyle(Console.blue).padding(9).lineLimit(1)
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            Text(numberedSource).font(Console.mono(11)).lineSpacing(3).foregroundStyle(Console.text)
                                .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                                .frame(minWidth: max(0, geometry.size.width - 24), alignment: .topLeading)
                                .padding(.horizontal, 12).padding(.bottom, 10)
                        }
                    }
                }
            } else if studentTab == "CLI SESSION" {
                studentCLI
            } else {
                studentOutput(controller.buildLines.joined(separator: "\n"), empty: "Run CMake with RUN BUILD. Compilation does not establish runtime correctness.")
            }
        }.benchSurface()
    }

    var numberedSource: String {
        guard let text = controller.sourceText else { return "Source file not found in the selected project." }
        return text.components(separatedBy: "\n").enumerated().map { String(format: "%4d  %@", $0.offset + 1, $0.element) }.joined(separator: "\n")
    }

    var studentCLI: some View {
        VStack(spacing: 0) {
            CLITerminalSurface(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            HStack {
                Text("CLICK TERMINAL TO TYPE · RETURN TO SUBMIT")
                Spacer()
                Text(controller.programRunning ? "RUNNING" : controller.programExitCode.map { "EXIT \($0)" } ?? "NOT RUN")
            }.font(Console.mono(8)).foregroundStyle(Console.muted)
                .padding(.horizontal, 12).frame(height: 24)
                .overlay(alignment: .top) { Rectangle().fill(Console.line).frame(height: 1) }
        }
    }

    func studentOutput(_ text: String, empty: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? empty : text).font(Console.mono(11)).lineSpacing(3)
                        .foregroundStyle(text.isEmpty ? Console.muted : Console.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                    Color.clear.frame(height: 1).id("student-output-end")
                }.padding(12)
            }.onChange(of: text) { _ in proxy.scrollTo("student-output-end", anchor: .bottom) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CLITerminalSurface: NSViewRepresentable {
    let controller: ProjectConsoleController

    func makeNSView(context: Context) -> CLITerminalView {
        let view = controller.cliTerminal
        view.nativeBackgroundColor = NSColor(Console.panel)
        view.nativeForegroundColor = NSColor(Console.text)
        if !controller.programRunning, controller.programExitCode == nil {
            view.resetSession()
            view.feed(text: "Build, then RUN CLI. Type at the prompt; Return submits input.\r\n")
        }
        return view
    }

    func updateNSView(_ view: CLITerminalView, context: Context) {}
}

private struct BenchPanel<Content: View, Actions: View>: View {
    let title: String
    let index: String
    let caption: String
    let actions: Actions
    let content: Content

    init(_ title: String, index: String = "", caption: String = "", @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title; self.index = index; self.caption = caption
        self.actions = actions(); self.content = content()
    }

    init(_ title: String, index: String = "", caption: String = "", @ViewBuilder content: () -> Content) where Actions == EmptyView {
        self.init(title, index: index, caption: caption, actions: { EmptyView() }, content: content)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !index.isEmpty { Text(index).font(Console.mono(11, weight: .semibold)).foregroundStyle(Console.red) }
                Text(title).font(Console.mono(10, weight: .medium)).tracking(1.1).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if !caption.isEmpty { Text(caption).font(Console.mono(8)).foregroundStyle(Console.muted).lineLimit(1) }
                actions
            }.padding(.horizontal, 12).frame(height: title == "PROJECT STATE" || title == "CURRENT WORK" ? 30 : 35)
                .background(Console.raised.opacity(0.35)).benchRule()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.benchSurface()
    }
}

private extension View {
    func benchRule() -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Console.line.opacity(0.65)).frame(height: 1) }
    }
    func benchSurface() -> some View {
        background(Console.panel.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Console.border))
            .overlay(alignment: .topLeading) { Rectangle().fill(Console.red).frame(width: 24, height: 1) }
    }
}
