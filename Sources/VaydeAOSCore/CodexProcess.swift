import Foundation

/// JSON values keep the bidirectional app-server protocol independent of SDK bindings.
enum CodexValue: Codable, Equatable, Sendable {
    case object([String: CodexValue]), array([CodexValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: CodexValue].self) { self = .object(v) }
        else { self = .array(try c.decode([CodexValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> CodexValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var text: String? { if case .string(let v) = self { return v }; return nil }
    var values: [CodexValue] { if case .array(let v) = self { return v }; return [] }
    var fields: [String: CodexValue] { if case .object(let v) = self { return v }; return [:] }
    var flag: Bool { self == .bool(true) }
    var pretty: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? ""
    }
}

public enum CodexRuntimeError: LocalizedError {
    case unavailable, disconnected, invalidProtocol, timedOut, requestFailed(String), turnFailed, busy, emptyReply, signInRequired, accountReviewRequired
    case processExited(status: Int32, signaled: Bool)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The bundled Codex runtime is missing. Rebuild VaydeAOS with its runtime packaging step."
        case .disconnected: return "Codex disconnected. Completed tool actions may remain; inspect the activity before retrying."
        case .invalidProtocol: return "Codex returned an unsupported protocol message."
        case .processExited(let status, let signaled): return "Codex exited with \(signaled ? "signal" : "status") \(status). Completed tool actions may remain; inspect the activity before retrying."
        case .timedOut: return "Codex timed out. Completed tool actions may remain."
        case .requestFailed(let method): return "Codex could not complete \(method). Check its account, model, workspace, and MCP configuration."
        case .turnFailed: return "The Codex turn failed. Completed tool actions may remain; inspect the activity before retrying."
        case .busy: return "Stop the active Codex task before starting another."
        case .emptyReply: return "Codex completed without an assistant reply. Inspect the tool activity before retrying."
        case .signInRequired: return "Connect your ChatGPT account in Connection Settings before sending a message."
        case .accountReviewRequired: return "Confirm the displayed ChatGPT account in Connection Settings after merging the connections."
        }
    }
}

/// Owns exactly one child process. No shell invocation, listening socket, or credential copying.
@MainActor
final class CodexProcess {
    var onMessage: ((String, CodexValue, CodexValue?) -> Void)?
    var onDisconnect: ((CodexRuntimeError) -> Void)?
    private let executable: URL?
    private let environment: [String: String]?
    private var child: Process?
    private var input: FileHandle?
    private var startup: Task<Void, Error>?
    private var generation = UUID()
    private var buffer = Data()
    private struct Pending {
        let continuation: CheckedContinuation<CodexValue, Error>
        let timer: Task<Void, Never>
        let method: String
    }
    private var pending: [String: Pending] = [:]

    init(executable: URL? = Bundle.main.resourceURL?.appendingPathComponent("Codex/bin/codex"),
         environment: [String: String]? = nil) {
        self.executable = executable; self.environment = environment
    }
    deinit {
        try? input?.close()
        if child?.isRunning == true { child?.terminate() }
        for item in pending.values { item.timer.cancel(); item.continuation.resume(throwing: CodexRuntimeError.disconnected) }
    }

    func connect() async throws {
        if let startup { return try await startup.value }
        let task = Task { @MainActor in
            try launch()
            _ = try await request("initialize", .object([
                "clientInfo": .object(["name": .string("vaydeaos"), "title": .string("VaydeAOS"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            try write(.object(["method": .string("initialized")]))
        }
        startup = task
        do { try await task.value } catch { stop(); throw error }
    }

    func request(_ method: String, _ params: CodexValue = .object([:]), timeout: UInt64 = 90) async throws -> CodexValue {
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000) } catch { return }
                    guard let self, let item = self.pending.removeValue(forKey: id) else { return }
                    item.continuation.resume(throwing: CodexRuntimeError.timedOut)
                    self.stop()
                }
                pending[id] = Pending(continuation: continuation, timer: timer, method: method)
                do { try write(.object(["id": .string(id), "method": .string(method), "params": params])) }
                catch { stop() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let item = self?.pending.removeValue(forKey: id) else { return }
                item.timer.cancel(); item.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func respond(_ id: CodexValue, result: CodexValue) {
        do { try write(.object(["id": id, "result": result])) } catch { stop() }
    }
    func reject(_ id: CodexValue) {
        do { try write(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported client request")])])) }
        catch { stop() }
    }
    func interrupt(thread: String, turn: String) {
        // Write synchronously before shutting down the child; do not enqueue this after stop().
        try? write(.object(["id": .string(UUID().uuidString), "method": .string("turn/interrupt"),
            "params": .object(["threadId": .string(thread), "turnId": .string(turn)])]))
    }

    func stop(error: CodexRuntimeError = .disconnected) {
        generation = UUID()
        startup?.cancel(); startup = nil
        try? input?.close(); input = nil
        if let child, child.isRunning {
            child.terminate()
            // SIGTERM is best effort; do not leave an unresponsive runtime working indefinitely.
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        child = nil; buffer = Data()
        let requests = pending; pending = [:]
        for item in requests.values { item.timer.cancel(); item.continuation.resume(throwing: error) }
        onDisconnect?(error)
    }

    private func launch() throws {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodexRuntimeError.unavailable }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        let ambient = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "CODEX_HOME"] { env[key] = ambient[key] }
        let tools = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("codex-path").path
        env["PATH"] = tools + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = environment ?? env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let current = UUID(); generation = current
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw CodexRuntimeError.unavailable }
        child = process; input = stdin.fileHandleForWriting
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading
        // Read on a dedicated queue and acknowledge each chunk before reading more.
        // The OS pipe supplies backpressure when the UI is busy: protocol bytes are
        // never dropped, and memory does not grow with an unbounded stream queue.
        DispatchQueue(label: "VaydeAOS.Codex.stdout.\(current)").async { [weak self] in
            defer { try? output.close() }
            while true {
                let data = output.availableData
                if data.isEmpty { break }
                let consumed = DispatchSemaphore(value: 0)
                Task { @MainActor [weak self] in
                    defer { consumed.signal() }
                    self?.receive(data, generation: current)
                }
                consumed.wait()
            }
            // EOF follows the final bytes. A process termination callback can run
            // earlier and erase a completed turn before those bytes are consumed.
            // Reaping can also lag EOF. Wait briefly off the main actor so an exit
            // status is available, without hanging if a live child closes stdout.
            _ = exited.wait(timeout: .now() + 0.2)
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                let error: CodexRuntimeError = process.isRunning ? .disconnected
                    : .processExited(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal)
                self.stop(error: error)
            }
        }
    }
    private func write(_ value: CodexValue) throws {
        guard let input, child?.isRunning == true else { throw CodexRuntimeError.disconnected }
        var data = try JSONEncoder().encode(value); data.append(10)
        try input.write(contentsOf: data)
    }
    private func receive(_ data: Data, generation current: UUID) {
        guard current == generation else { return }
        buffer.append(data)
        // Prevent a broken or hostile child from allocating unbounded protocol buffers.
        guard buffer.count <= 16 * 1024 * 1024 else { stop(error: .requestFailed("protocol frame size limit")); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(CodexValue.self, from: line) else { stop(error: .invalidProtocol); return }
            let id = message["id"]
            if let method = message["method"].text {
                onMessage?(method, message["params"], id == .null ? nil : id)
            } else if let key = id.text, let item = pending.removeValue(forKey: key) {
                item.timer.cancel()
                if message["error"] != .null { item.continuation.resume(throwing: CodexRuntimeError.requestFailed(item.method)) }
                else { item.continuation.resume(returning: message["result"]) }
            }
        }
    }
}
