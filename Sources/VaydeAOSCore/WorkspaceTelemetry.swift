import Foundation

public struct WorkspaceProjectSnapshot: Sendable {
    public var directory: String
    public var repository: String
    public var branch: String
    public var commit: String
    public var commitDate: String
    public var changedFiles: Int
    public var target: String
    public var suggestedCommand: String
    public var isRepository: Bool

    /// Local reads only. Call from a background task; no fetch, checkout, or index refresh.
    public static func read(directory: String) -> Self {
        let root = URL(fileURLWithPath: directory)
        func git(_ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["--no-optional-locks", "-C", directory] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return "" }
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            } catch { return "" }
        }
        let valid = git(["rev-parse", "--is-inside-work-tree"]) == "true"
        let status = git(["status", "--short", "--untracked-files=normal"])
        let branch = git(["symbolic-ref", "--short", "-q", "HEAD"])
        let files = FileManager.default
        let swift = files.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
        let hostTests = files.fileExists(atPath: root.appendingPathComponent("tests/run_host_tests.sh").path)
        let buildScript = files.fileExists(atPath: root.appendingPathComponent("build.sh").path)
        let platformIO = files.fileExists(atPath: root.appendingPathComponent("platformio.ini").path)
        let cmake = files.fileExists(atPath: root.appendingPathComponent("CMakeLists.txt").path)
        let command = hostTests ? "bash tests/run_host_tests.sh" : buildScript ? "./build.sh" : swift ? "swift build" : platformIO ? "pio run" : cmake ? "cmake -S . -B build && cmake --build build" : ""
        return Self(directory: directory, repository: root.lastPathComponent,
                    branch: valid ? (branch.isEmpty ? "detached HEAD" : branch) : "No Git repository",
                    commit: git(["rev-parse", "--short", "HEAD"]), commitDate: git(["log", "-1", "--format=%cr"]),
                    changedFiles: status.split(separator: "\n").count,
                    target: swift ? "Native macOS / Swift" : hostTests ? "C++ host verification" : platformIO ? "PlatformIO" : cmake ? "CMake" : "Choose a build command",
                    suggestedCommand: command, isRepository: valid)
    }
}

public struct WorkspacePacket: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var date: Date
    public var direction: String
    public var outbound: Bool { direction == "TX" }
    public var deliveryConfirmed: Bool {
        direction == "RX" && ["OK", "RECEIVED", "DELIVERED"].contains(result.uppercased())
    }
    public var transport: String
    public var sender: String
    public var sequence: String
    public var result: String
    public var info: String

    /// Accept explicit JSON records or the actual VaydeNet NodeMessageSink log schema.
    /// Startup messages and heartbeat submissions are not packet-delivery evidence.
    public static func parse(_ line: String, at date: Date = Date()) -> Self? {
        if let start = line.firstIndex(of: "{"), let data = String(line[start...]).data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let transport = json["transport"] as? String,
           let sequence = json["sequence"] ?? json["sequenceNumber"],
           let sender = json["sender"] ?? json["senderID"] {
            let reportedDirection = (json["direction"] as? String)?.uppercased() ?? ""
            return Self(date: date, direction: ["TX", "RX"].contains(reportedDirection) ? reportedDirection : "—",
                        transport: transport, sender: String(describing: sender), sequence: String(describing: sequence),
                        result: json["result"] as? String ?? "REPORTED", info: String(line.prefix(500)))
        }
        func capture(_ pattern: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[range])
        }
        guard line.contains("Logical message delivered:"), let source = capture("source=([0-9]+)"),
              let sequence = capture("sequence=([0-9]+)"), line.contains("payload=") else { return nil }
        return Self(date: date, direction: "RX", transport: "VaydeNet", sender: source,
                    sequence: sequence, result: "RECEIVED", info: capture("payload=\"(.*)\"") ?? String(line.prefix(500)))
    }
}
