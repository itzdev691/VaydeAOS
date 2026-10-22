import AppKit
import CoreGraphics
import Foundation

// Launch-only smoke test. This does not exercise controls or assert visual fidelity.
func smokeTest() throws {
    guard CommandLine.arguments.count == 3 else {
        throw failure("Usage: swift scripts/ci-ui-smoke.swift <app> <log>")
    }
    let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    guard let bundle = Bundle(url: appURL), let executable = bundle.executableURL else {
        throw failure("App bundle or executable is missing: \(appURL.path)")
    }
    if let identifier = bundle.bundleIdentifier,
       !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
        throw failure("Quit the existing \(identifier) instance before running the smoke test.")
    }

    let logURL = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(
        at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }

    let process = Process()
    process.executableURL = executable
    process.standardOutput = log
    process.standardError = log
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    let deadline = Date().addingTimeInterval(30)
    var windowPresentSince: Date?
    while Date() < deadline {
        guard process.isRunning else {
            throw failure("App exited during startup with status \(process.terminationStatus). See \(logURL.path).")
        }
        // A main window may open on another Space; focus is not a launch requirement.
        let windows = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID)
            as? [[String: Any]] ?? []
        let hasWindow = windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return pid == process.processIdentifier && layer == 0
                && (bounds["Width"] ?? 0) >= 800 && (bounds["Height"] ?? 0) >= 600
        }
        if hasWindow {
            if windowPresentSince == nil { windowPresentSince = Date() }
            // Cover the intro and staged workspace reveal, then observe the live window.
            if let since = windowPresentSince, Date().timeIntervalSince(since) >= 10 {
                print("PASS: native main window existed and the app stayed alive for 10 seconds.")
                return
            }
        } else {
            windowPresentSince = nil
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw failure("No stable native window within 30 seconds. A logged-in macOS desktop is required.")
}

func failure(_ message: String) -> NSError {
    NSError(domain: "VaydeAOS.CI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

do {
    try smokeTest()
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
    exit(1)
}
