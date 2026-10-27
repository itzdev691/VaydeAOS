import AppKit
import Darwin
import Foundation
import VaydeAOSCore

@main struct ControllerCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let model = ProjectConsoleController()
        model.configure(directory: "/tmp", command: "printf 'first\\nlast\\n'; exit 0")
        model.runBuild()
        for _ in 0..<200 where model.buildRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(model.buildExitCode == 0, "build success missing")
        precondition(model.buildLines.contains("first") && model.buildLines.contains("last"), "output missing")
        model.command = "printf 'failure\\n' >&2; exit 7"
        model.runBuild()
        for _ in 0..<200 where model.buildRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(model.buildExitCode == 7 && model.issue != nil, "exit failure missing")
        precondition(model.buildLines.contains("failure"), "stderr missing")
        model.command = "for i in {1..20000}; do printf 'line %s padding padding padding padding padding padding padding padding\\n' $i; done; printf 'FINAL-MARKER\\n'"
        model.runBuild()
        for _ in 0..<400 where model.buildRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(model.buildExitCode == 0, "burst deadlocked")
        precondition(model.buildLines.contains("FINAL-MARKER"), "final output not drained")
        precondition(model.buildLines.count <= 1000, "unbounded build output")
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 1024)
        precondition(openpty(&master, &slave, &name, nil, nil) == 0)
        close(slave)
        model.connect(ConsoleDevice(port: String(cString: name)))
        precondition(model.connectedPort != nil, "PTY serial connection failed")
        let payload = "{\"transport\":\"ESP-NOW\",\"sender\":\"test\",\"sequence\":1,\"result\":\"OK\"}\n"
        payload.withCString { ptr in _ = write(master, ptr, strlen(ptr)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(model.packets.count == 1, "packet not decoded")
        model.paused = true
        payload.withCString { ptr in _ = write(master, ptr, strlen(ptr)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(model.packets.count == 1 && model.serialLines.count == 2, "pause did not preserve raw serial")
        model.disconnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        close(master)
        model.shutdown()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent(StudentDBWorkspace.executable)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        printf 'CLI prompt: '
        IFS= read -r choice
        printf '\\naccepted:%s\\n' "$choice"
        stty -echo
        printf 'Password: '
        IFS= read -r secret
        stty echo
        printf '\\nsecret accepted\\n'
        stty size
        printf 'fixture record' > students.txt
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let registry = ProjectConsoleRegistry()
        let studentID = UUID()
        let student = registry.console(for: studentID)
        let other = registry.console(for: UUID())
        student.configure(directory: root.path, command: "true", studentDB: true)
        student.runProgram()
        for _ in 0..<100 where !student.programOutput.contains("CLI prompt:") { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(student.programRunning && student.programOutput.contains("CLI prompt:"), "interactive prompt missing")
        precondition(registry.console(for: studentID) === student, "workspace lost its controller")
        precondition(!other.programRunning && other.programOutput.isEmpty, "CLI state crossed workspace boundary")
        let terminalWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 180),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        terminalWindow.isReleasedWhenClosed = false
        terminalWindow.contentView = student.cliTerminal
        student.cliTerminal.focusForInput()
        precondition(terminalWindow.firstResponder === student.cliTerminal, "terminal did not accept keyboard focus")
        student.resizeProgram(cols: 97, rows: 19)
        student.cliTerminal.insertText("visible-inputX", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<100 where !student.programOutput.contains("visible-inputX") { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(student.programOutput.contains("visible-inputX"), "normal input did not echo before Return")
        precondition(other.programOutput.isEmpty, "input crossed workspace boundary")
        for (key, code) in [("\u{7f}", UInt16(51)), ("\r", UInt16(36))] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: terminalWindow.windowNumber, context: nil,
                                        characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            student.cliTerminal.keyDown(with: event)
        }
        for _ in 0..<100 where !student.programOutput.contains("Password:") { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(student.programOutput.contains("accepted:visible-input\r\n"), "Backspace or Return did not reach the terminal")
        student.sendProgramInput(Array("private-input-marker\r".utf8)[...])
        for _ in 0..<100 where student.programRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(student.programExitCode == 0 && student.programOutput.contains("accepted"), "interactive input failed")
        precondition(!student.programOutput.contains("private-input-marker"), "terminal echoed private input")
        precondition(student.recordBytes == 14 && student.programOutput.contains("19 97"), "record cwd or terminal resize failed")
        let terminal = student.cliTerminal
        terminal.resetSession()
        terminal.feed(text: "first\r\nsecond\r\u{1b}[2K\u{1b}[31mreplacement\u{1b}[0m")
        let rendered = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
        precondition(rendered.contains("first") && rendered.contains("replacement") && !rendered.contains("second") && !rendered.contains("[31m"), "ANSI/cursor rendering failed")
        let unicode = Array("é".utf8)
        terminal.feed(byteArray: unicode.prefix(1)); terminal.feed(byteArray: unicode.suffix(1))
        precondition(String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("replacementé"), "split UTF-8 corrupted terminal output")
        let retained = student.cliTerminal
        precondition(registry.console(for: studentID).cliTerminal === retained && other.cliTerminal !== retained, "terminal state crossed workspace boundary")
        try "#!/bin/sh\ntrap 'exit 42' INT\nprintf 'signal-ready\\n'\nwhile :; do sleep 1; done\n".write(to: executable, atomically: true, encoding: .utf8)
        student.runProgram()
        for _ in 0..<100 where !student.programOutput.contains("signal-ready") { try await Task.sleep(nanoseconds: 20_000_000) }
        student.sendProgramInput([0x03][...])
        for _ in 0..<150 where student.programRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(student.programExitCode == 42, "Ctrl-C did not signal the foreground process")
        try "#!/bin/sh\nwhile :; do :; done\n".write(to: executable, atomically: true, encoding: .utf8)
        student.runProgram()
        student.stopProgram()
        for _ in 0..<150 where student.programRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(!student.programRunning, "CLI stop did not end the process")
        terminalWindow.close()
        registry.shutdown()
        print("PASS: subprocess output/exit codes, burst drain, serial capture, inline terminal echo, Backspace/Return, program-controlled password hiding, resize, ANSI/cursor and split UTF-8 rendering, Ctrl-C, stop, record cwd, workspace isolation")
    }
}
