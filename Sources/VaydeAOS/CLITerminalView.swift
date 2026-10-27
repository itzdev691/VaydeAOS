import AppKit
import SwiftUI
import SwiftTerm

/// Retained by the workspace controller so cursor state and scrollback survive navigation.
final class CLITerminalView: TerminalView, TerminalViewDelegate {
    private weak var controller: ProjectConsoleController?

    init(controller: ProjectConsoleController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 170),
                   font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                   options: TerminalOptions(scrollback: 2000))
        terminalDelegate = self
        setAccessibilityLabel("StudentDB CLI terminal")
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if controller?.programRunning == true { focusForInput() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    func focusForInput() { window?.makeFirstResponder(self) }

    func resetSession() {
        feed(text: "\u{1b}c")
        clearScrollback()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { controller?.sendProgramInput(data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        controller?.resizeProgram(cols: newCols, rows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
