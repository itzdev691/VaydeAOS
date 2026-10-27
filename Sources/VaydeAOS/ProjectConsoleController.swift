import AppKit
import Darwin
import SwiftUI
import SwiftTerm
import VaydeAOSCore

/// Retains running jobs and serial ownership when navigating between workspaces.
@MainActor
final class ProjectConsoleRegistry: ObservableObject {
    private var consoles: [UUID: ProjectConsoleController] = [:]
    func console(for id: UUID) -> ProjectConsoleController {
        if let console = consoles[id] { return console }
        let console = ProjectConsoleController()
        consoles[id] = console
        return console
    }
    func shutdown() { consoles.values.forEach { $0.shutdown() } }
}

struct ConsoleDevice: Identifiable {
    var id: String { port }
    let port: String
    var name: String { URL(fileURLWithPath: port).lastPathComponent.replacingOccurrences(of: "cu.", with: "") }
}

struct ConsoleEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    var warning = false
}

@MainActor
final class ProjectConsoleController: ObservableObject {
    @Published private(set) var snapshot: WorkspaceProjectSnapshot?
    @Published private(set) var devices: [ConsoleDevice] = []
    @Published private(set) var packets: [WorkspacePacket] = []
    @Published private(set) var serialLines: [String] = []
    @Published private(set) var buildLines: [String] = []
    @Published private(set) var events: [ConsoleEvent] = []
    @Published private(set) var connectedPort: String?
    @Published private(set) var buildRunning = false
    @Published private(set) var buildExitCode: Int32?
    @Published private(set) var buildFinishedAt: Date?
    @Published private(set) var lastSerialAt: Date?
    @Published private(set) var issue: String?
    @Published var paused = false
    @Published var baud: Int = 115200
    @Published var command = ""
    @Published private(set) var directory = ""
    @Published private(set) var programOutput = ""
    @Published private(set) var programRunning = false
    @Published private(set) var programExitCode: Int32?
    @Published private(set) var sourceText: String?
    @Published private(set) var sourcePath = "src/main.cpp"
    @Published private(set) var recordBytes: Int?
    lazy var cliTerminal = CLITerminalView(controller: self)
    private var programPID: pid_t?
    private var programMonitor: DispatchSourceProcess?
    private var programFD: Int32 = -1
    private var programSource: DispatchSourceRead?
    private var programWriteSource: DispatchSourceWrite?
    private var programPendingInput = Data()
    private var programGeneration = UUID()
    private var process: Process?
    private var buildPipe: Pipe?
    private var buildSource: DispatchSourceRead?
    private var serialFD: Int32 = -1
    private var serialSource: DispatchSourceRead?
    private var serialBuffer = Data()
    private var buildBuffer = Data()
    private var polling = false
    private var generation = UUID()
    private var studentDBMode = false

    func configure(directory: String, command: String?, studentDB: Bool = false) {
        studentDBMode = studentDB
        guard self.directory != directory else {
            if let command, !buildRunning { self.command = command }
            return
        }
        guard !buildRunning, !programRunning else { return }
        disconnect()
        generation = UUID()
        self.directory = directory
        self.command = command ?? ""
        snapshot = nil
        buildExitCode = nil
        buildFinishedAt = nil
        buildLines = []
        serialLines = []
        packets = []
        issue = nil
        programOutput = ""
        cliTerminal.resetSession()
        programExitCode = nil
        sourceText = nil
        recordBytes = nil
        record("Project selected: \(directory)")
    }

    func refresh() async {
        guard !polling, !directory.isEmpty else { return }
        polling = true
        let currentDirectory = directory
        let currentGeneration = generation
        let value = await Task.detached(priority: .utility) {
            WorkspaceProjectSnapshot.read(directory: currentDirectory)
        }.value
        defer { polling = false }
        guard currentGeneration == generation else { return }
        if let previous = snapshot, previous.commit != value.commit || previous.changedFiles != value.changedFiles {
            record("Repository updated: \(value.changedFiles) changed files · \(value.commit)")
        }
        snapshot = value
        if command.isEmpty { command = value.suggestedCommand }
        if studentDBMode {
            selectSource(sourcePath)
            refreshRecord()
            return
        }
        let ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usb") || $0.hasPrefix("cu.wch") || $0.hasPrefix("cu.SLAB") }
            .sorted().map { ConsoleDevice(port: "/dev/" + $0) }
        if ports.map(\.port) != devices.map(\.port) {
            devices = ports
            record("USB serial discovery: \(ports.count) ports")
        }
        if let connectedPort, !ports.contains(where: { $0.port == connectedPort }) {
            disconnect()
            fail("Serial device disconnected")
        }
    }

    func chooseDirectory() -> String? {
        guard !buildRunning, !programRunning else { return nil }
        let panel = NSOpenPanel()
        panel.title = "Select workspace project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func connect(_ device: ConsoleDevice) {
        if connectedPort == device.port { disconnect(); return }
        disconnect()
        let descriptor = Darwin.open(device.port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { fail("Cannot open \(device.port): \(String(cString: strerror(errno)))"); return }
        guard ioctl(descriptor, TIOCEXCL) == 0 else {
            Darwin.close(descriptor); fail("Serial port is already in use"); return
        }
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            _ = ioctl(descriptor, TIOCNXCL); Darwin.close(descriptor); fail("Cannot read serial settings"); return
        }
        cfmakeraw(&settings)
        cfsetspeed(&settings, speed_t(baud))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            _ = ioctl(descriptor, TIOCNXCL); Darwin.close(descriptor); fail("Cannot set serial baud rate"); return
        }
        serialFD = descriptor
        connectedPort = device.port
        issue = nil
        serialBuffer = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.readSerial() }
        source.setCancelHandler { _ = ioctl(descriptor, TIOCNXCL); Darwin.close(descriptor) }
        serialSource = source
        source.resume()
        record("Serial connected: \(device.name) at \(baud) baud")
    }

    func disconnect() {
        if connectedPort != nil { record("Serial disconnected") }
        serialSource?.cancel()
        serialSource = nil
        serialFD = -1
        connectedPort = nil
        lastSerialAt = nil
    }

    private func readSerial() {
        guard serialFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(serialFD, &bytes, bytes.count)
        if count > 0 {
            lastSerialAt = Date()
            serialBuffer.append(contentsOf: bytes.prefix(count))
            consumeLines(&serialBuffer) { [weak self] line in
                guard let self else { return }
                self.serialLines.append(line)
                self.trim(&self.serialLines)
                if let packet = WorkspacePacket.parse(line), !self.paused {
                    self.packets.append(packet)
                    if self.packets.count > 500 { self.packets.removeFirst(self.packets.count - 500) }
                }
                if line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("failed") {
                    self.record(String(line.prefix(200)), warning: true)
                }
            }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            disconnect(); fail("Serial connection closed")
        }
    }

    func runBuild() {
        guard !buildRunning, !programRunning, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Release serial ownership before build tools optionally open their monitor.
        disconnect()
        let job = Process()
        let pipe = Pipe()
        job.executableURL = URL(fileURLWithPath: "/bin/zsh")
        job.arguments = ["-l", "-c", command]
        job.currentDirectoryURL = URL(fileURLWithPath: directory)
        job.standardOutput = pipe
        job.standardError = pipe
        job.standardInput = FileHandle.nullDevice
        buildLines = ["$ \(command)", "Working directory: \(directory)"]
        buildBuffer = Data()
        buildExitCode = nil
        buildFinishedAt = nil
        issue = nil
        do {
            try job.run()
            process = job
            buildPipe = pipe
            buildRunning = true
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.readBuildOutput() }
            buildSource = source
            source.resume()
            job.terminationHandler = { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.readBuildOutput()
                    self.finishBuild(code: finished.terminationStatus)
                }
            }
            // Also handles commands which exit before the termination handler was assigned.
            if !job.isRunning { readBuildOutput(); finishBuild(code: job.terminationStatus) }
            record("Build started: \(command)")
        } catch { fail("Build could not start: \(error.localizedDescription)") }
    }

    private func readBuildOutput() {
        guard let pipe = buildPipe else { return }
        var bytes = [UInt8](repeating: 0, count: 16384)
        // Bound each main-thread drain; DispatchSource schedules remaining output.
        for _ in 0..<16 {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            buildBuffer.append(contentsOf: bytes.prefix(count))
            consumeLines(&buildBuffer) { [weak self] line in
                self?.buildLines.append(line)
            }
        }
        trim(&buildLines)
    }

    private func finishBuild(code: Int32) {
        guard buildRunning else { return }
        if !buildBuffer.isEmpty { buildLines.append(String(decoding: buildBuffer, as: UTF8.self)); buildBuffer.removeAll() }
        buildSource?.cancel(); buildSource = nil
        try? buildPipe?.fileHandleForReading.close(); buildPipe = nil
        process = nil
        buildRunning = false
        buildExitCode = code
        buildFinishedAt = Date()
        record("Build \(code == 0 ? "passed" : "failed") · exit \(code)", warning: code != 0)
        if code != 0 { issue = "Build failed (exit \(code)). Inspect build output." }
    }

    func clearPackets() { packets = [] }
    func clearSerial() { serialLines = [] }
    func clearBuild() { buildLines = [] }
    func shutdown() { disconnect(); process?.interrupt(); stopProgram() }

    func selectSource(_ path: String) {
        sourcePath = path
        sourceText = StudentDBWorkspace.readSource(path, directory: directory)
    }

    private func refreshRecord() {
        let path = URL(fileURLWithPath: directory).appendingPathComponent("students.txt").path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        recordBytes = (attributes?[.size] as? NSNumber)?.intValue
    }

    /// The CLI owns its controlling terminal and decides when input should echo.
    func runProgram() {
        guard !programRunning, !buildRunning else { return }
        let executable = URL(fileURLWithPath: directory).appendingPathComponent(StudentDBWorkspace.executable)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            fail("Build StudentDB before running the CLI."); return
        }
        let terminal = cliTerminal
        let dimensions = terminal.getTerminal()
        var size = winsize(ws_row: UInt16(clamping: dimensions.rows), ws_col: UInt16(clamping: dimensions.cols), ws_xpixel: 0, ws_ypixel: 0)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        guard let child = PseudoTerminalHelpers.fork(andExec: executable.path, args: [executable.path],
            env: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory, desiredWindowSize: &size) else {
            fail("Cannot start CLI terminal"); return
        }
        let master = child.masterFd
        programOutput = "Working directory: \(directory)\r\n"
        terminal.resetSession()
        terminal.feed(text: programOutput)
        issue = nil
        programPendingInput.removeAll()
        programExitCode = nil
        let token = UUID()
        programGeneration = token
        programPID = child.pid; programFD = master; programRunning = true
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        source.setEventHandler { [weak self] in self?.readProgramOutput() }
        source.setCancelHandler { Darwin.close(master) }
        programSource = source; source.resume()
        let monitor = DispatchSource.makeProcessSource(identifier: child.pid, eventMask: .exit, queue: .main)
        monitor.setEventHandler { [weak self] in
            self?.finishProgram(pid: child.pid, generation: token)
        }
        programMonitor = monitor; monitor.resume()
        record("StudentDB CLI started")
        terminal.focusForInput()
    }

    func sendProgramInput(_ bytes: ArraySlice<UInt8>) {
        guard programRunning, programFD >= 0 else { return }
        guard programPendingInput.count + bytes.count <= 1_048_576 else { fail("CLI input is too large"); return }
        programPendingInput.append(contentsOf: bytes)
        drainProgramInput()
    }

    private func drainProgramInput() {
        while !programPendingInput.isEmpty, programFD >= 0 {
            let sent = programPendingInput.withUnsafeBytes { Darwin.write(programFD, $0.baseAddress, $0.count) }
            if sent > 0 { programPendingInput.removeFirst(sent); continue }
            if sent < 0, errno == EINTR { continue }
            if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if programWriteSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: programFD, queue: .main)
                    source.setEventHandler { [weak self] in self?.drainProgramInput() }
                    programWriteSource = source; source.resume()
                }
                return
            }
            programPendingInput.removeAll()
            fail("CLI input could not be sent")
            break
        }
        programWriteSource?.cancel(); programWriteSource = nil
    }

    func resizeProgram(cols: Int, rows: Int) {
        guard programFD >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: programFD, windowSize: &size)
    }

    func stopProgram() {
        guard let pid = programPID, programRunning else { return }
        let token = programGeneration
        kill(-pid, SIGTERM)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if self.programRunning, self.programGeneration == token { kill(-pid, SIGKILL) }
        }
    }

    func clearProgram() {
        programOutput = ""
        cliTerminal.feed(text: "\u{1b}[2J\u{1b}[H")
        cliTerminal.clearScrollback()
    }

    private func readProgramOutput() {
        guard programFD >= 0 else { return }
        var data = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            let count = Darwin.read(programFD, &data, data.count)
            guard count > 0 else { break }
            cliTerminal.feed(byteArray: data.prefix(count))
            programOutput += String(decoding: data.prefix(count), as: UTF8.self)
        }
        if programOutput.count > 128_000 { programOutput = String(programOutput.suffix(128_000)) }
    }

    private func finishProgram(pid: pid_t, generation: UUID) {
        guard generation == programGeneration, programRunning else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        readProgramOutput()
        programMonitor?.cancel(); programMonitor = nil
        programWriteSource?.cancel(); programWriteSource = nil
        programPendingInput.removeAll()
        programSource?.cancel(); programSource = nil
        programFD = -1; programPID = nil; programRunning = false
        programExitCode = code
        refreshRecord()
        record("StudentDB CLI exited · code \(code)", warning: code != 0)
    }

    private func consumeLines(_ buffer: inout Data, consume: (String) -> Void) {
        while let end = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<end], as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            buffer.removeSubrange(...end)
            consume(line)
        }
        // A broken/no-newline stream must not grow memory indefinitely.
        if buffer.count > 65536 { consume(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
    }
    private func trim(_ lines: inout [String]) {
        if lines.count > 1000 { lines.removeFirst(lines.count - 1000) }
    }
    private func fail(_ message: String) { issue = message; record(message, warning: true) }
    private func record(_ title: String, warning: Bool = false) {
        events.append(ConsoleEvent(title: title, warning: warning))
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
}
