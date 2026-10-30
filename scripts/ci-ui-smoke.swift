import AppKit
import CoreGraphics
import Foundation

// Launch smoke test. Background mode also checks accessory policy and window suppression.
func smokeTest() throws {
    let backgroundLaunch = Array(CommandLine.arguments.dropFirst(3)) == ["--background"]
    guard CommandLine.arguments.count == 3 || (CommandLine.arguments.count == 4 && backgroundLaunch) else {
        throw failure("Usage: swift scripts/ci-ui-smoke.swift <app> <log> [--background]")
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
    process.environment = ProcessInfo.processInfo.environment.merging(["VAYDEAOS_DISABLE_VOICE": "1"]) { _, value in value }
    process.executableURL = executable
    if backgroundLaunch { process.arguments = ["--background"] }
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

    let startedAt = Date()
    let deadline = startedAt.addingTimeInterval(30)
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
                && (!backgroundLaunch || (window[kCGWindowIsOnscreen as String] as? Bool ?? false))
                && (bounds["Width"] ?? 0) >= 800 && (bounds["Height"] ?? 0) >= 600
        }
        if backgroundLaunch {
            let elapsed = Date().timeIntervalSince(startedAt)
            // Allow initial SwiftUI window creation to settle before checking suppression.
            if elapsed >= 2, hasWindow { throw failure("Background launch presented a workspace window.") }
            if elapsed >= 10 {
                guard NSRunningApplication(processIdentifier: process.processIdentifier)?.activationPolicy == .accessory else {
                    throw failure("Background app did not use accessory activation policy.")
                }
                print("PASS: background launch stayed running without a workspace window for 10 seconds, using accessory policy.")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
            continue
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
