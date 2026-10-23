import Foundation

public struct ChatGPTIdentity: Codable, Equatable, Sendable {
    public var name: String?
    public var email: String?
}

public struct ChatGPTSessionState: Codable, Equatable, Sendable {
    public var status: String
    public var sharing: Bool
    public var profileId: String?
    public var profileLabel: String?
    public var identity: ChatGPTIdentity?
    public var error: ChatGPTHelperError?
    public static let disconnected = Self(status: "disconnected", sharing: false)
    public var canUsePlan: Bool { status == "connected" && sharing }
}

public struct ChatGPTProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var status: String
    public var sharing: Bool
    public var pending: Bool?
    public var requiresNewRegistration: Bool?
    public var identity: ChatGPTIdentity?
    public var displayName: String { "\(label) · \(identity?.email ?? identity?.name ?? status)" }
}

public struct ChatGPTModel: Codable, Identifiable, Equatable, Sendable {
    public var slug: String
    public var displayName: String
    public var id: String { slug }
}

public struct ChatGPTHelperError: Codable, Error, LocalizedError, Equatable, Sendable {
    public var code: String
    public var message: String
    public var errorDescription: String? { message }
    static let unavailable = Self(code: "helper_unavailable", message: "The ChatGPT helper is unavailable. Build and launch the packaged VaydeAOS app.")
    static let interrupted = Self(code: "helper_stopped", message: "The ChatGPT helper stopped. Retry to restart the connection.")
    static let timedOut = Self(code: "helper_timeout", message: "The ChatGPT operation timed out. Retry the connection.")
}

public struct ChatGPTHelperRequest: Encodable, Sendable {
    public var id = UUID().uuidString
    public var method: String
    public var target: String?
    public var profileId: String?
    public var newProfile: Bool?
    public var reconsent: Bool?
    public var model: String?
    public var messages: [ChatMessage]?
    public init(method: String) { self.method = method }
}

public struct ChatGPTHelperResponse: Decodable, Sendable {
    public var id: String?
    public var kind: String
    public var session: ChatGPTSessionState?
    public var profiles: [ChatGPTProfile]?
    public var models: [ChatGPTModel]?
    public var text: String?
    public var delta: String?
    public var error: ChatGPTHelperError?
}

public protocol ChatGPTHelping: Sendable {
    func request(_ request: ChatGPTHelperRequest,
                 onDelta: (@Sendable (String) -> Void)?) async throws -> ChatGPTHelperResponse
    func shutdown() async
}

/// One local process, anonymous-pipe JSON messages, no permanent HTTP service.
/// The helper owns OAuth credentials; this protocol carries display data only.
public actor ChatGPTHelper: ChatGPTHelping {
    private let helperDirectory: URL?
    private let storageDirectory: URL
    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?
    private var generation = UUID()
    private var buffer = Data()
    private final class Pending {
        let continuation: CheckedContinuation<ChatGPTHelperResponse, Error>
        let onDelta: (@Sendable (String) -> Void)?
        let deadline: Task<Void, Never>
        var partialText = ""
        var lastPublish: TimeInterval = 0
        init(continuation: CheckedContinuation<ChatGPTHelperResponse, Error>,
             onDelta: (@Sendable (String) -> Void)?, deadline: Task<Void, Never>) {
            self.continuation = continuation; self.onDelta = onDelta; self.deadline = deadline
        }
    }
    private var pending: [String: Pending] = [:]

    public init(helperDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("ChatGPT"),
                storageDirectory: URL = LocalStore().directory.appendingPathComponent("ChatGPT")) {
        self.helperDirectory = helperDirectory
        self.storageDirectory = storageDirectory
    }

    deinit {
        readTask?.cancel()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        for entry in pending.values { entry.deadline.cancel(); entry.continuation.resume(throwing: ChatGPTHelperError.interrupted) }
    }

    public func request(_ request: ChatGPTHelperRequest,
                        onDelta: (@Sendable (String) -> Void)? = nil) async throws -> ChatGPTHelperResponse {
        try Task.checkCancellation()
        try startIfNeeded()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout: UInt64 = request.method == "signIn" ? 660 : request.method == "reply" ? 240 : 90
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000) } catch { return }
                    await self?.expire(request.id)
                }
                pending[request.id] = Pending(continuation: continuation, onDelta: onDelta, deadline: deadline)
                do { try write(request) }
                catch { failProcess() }
            }
        } onCancel: {
            Task { await self.cancel(request.id) }
        }
    }

    public func shutdown() { failProcess() }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        if process != nil { failProcess() }
        guard let directory = helperDirectory else { throw ChatGPTHelperError.unavailable }
        let node = directory.appendingPathComponent("node")
        let script = directory.appendingPathComponent("helper.mjs")
        let vault = directory.appendingPathComponent("credential-vault")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: script.path),
              FileManager.default.isExecutableFile(atPath: vault.path) else { throw ChatGPTHelperError.unavailable }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = node
        child.arguments = [script.path, storageDirectory.path]
        child.currentDirectoryURL = directory
        // No ambient API keys, SDK debug flags, dynamic loader hooks, or Node options.
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                             "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        let current = UUID()
        generation = current
        child.terminationHandler = { [weak self] _ in Task { await self?.processEnded(current) } }
        do { try child.run() } catch { throw ChatGPTHelperError.unavailable }
        process = child
        input = stdin.fileHandleForWriting
        // Close unused parent ends, so EOF follows helper exit or app shutdown.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading
        readTask = Task.detached { [weak self] in
            defer { try? output.close() }
            while !Task.isCancelled {
                // read(upToCount:) can wait for a full buffer on macOS pipes.
                // availableData returns each currently available protocol chunk.
                let data = output.availableData
                if data.isEmpty { break }
                await self?.receive(data, generation: current)
            }
            await self?.processEnded(current)
        }
    }

    private func write(_ request: ChatGPTHelperRequest) throws {
        var bytes = try JSONEncoder().encode(request)
        guard bytes.count <= 24 * 1024 * 1024 else {
            throw ChatGPTHelperError(code: "request_too_large", message: "The conversation is too large. Start a new chat.")
        }
        bytes.append(10)
        guard let input else { throw ChatGPTHelperError.interrupted }
        try input.write(contentsOf: bytes)
    }

    private func receive(_ data: Data, generation current: UUID) {
        guard generation == current else { return }
        buffer.append(data)
        guard buffer.count <= 32 * 1024 * 1024 else { failProcess(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            guard let response = try? JSONDecoder().decode(ChatGPTHelperResponse.self, from: line) else { failProcess(); return }
            buffer.removeSubrange(...newline)
            guard let id = response.id, let entry = pending[id] else { continue }
            if response.kind == "delta", let delta = response.delta {
                entry.partialText.append(delta)
                guard entry.partialText.utf8.count <= 64 * 1024 * 1024 else { failProcess(); return }
                // Small wire deltas; bounded UI updates carry cumulative snapshots
                // so late MainActor tasks cannot reorder or duplicate text.
                let now = ProcessInfo.processInfo.systemUptime
                if now - entry.lastPublish >= 1.0 / 30 {
                    entry.lastPublish = now
                    entry.onDelta?(entry.partialText)
                }
            }
            else if response.kind == "result" {
                pending.removeValue(forKey: id)
                entry.deadline.cancel()
                entry.continuation.resume(returning: response)
            }
        }
    }

    private func cancel(_ id: String) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.deadline.cancel()
        var request = ChatGPTHelperRequest(method: "cancel")
        request.target = id
        try? write(request)
        entry.continuation.resume(throwing: CancellationError())
    }

    private func expire(_ id: String) {
        guard pending[id] != nil else { return }
        failProcess(error: .timedOut)
    }

    private func processEnded(_ current: UUID) {
        guard generation == current else { return }
        failProcess()
    }

    private func failProcess(error: ChatGPTHelperError = .interrupted) {
        generation = UUID()
        readTask?.cancel(); readTask = nil
        try? input?.close(); input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        buffer = Data()
        let old = pending
        pending.removeAll()
        for entry in old.values { entry.deadline.cancel(); entry.continuation.resume(throwing: error) }
    }
}
