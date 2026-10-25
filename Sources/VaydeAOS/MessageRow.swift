import AppKit
import SwiftUI
import VaydeAOSCore

struct MessageRow: View {
    let message: ChatMessage
    @State private var copied = false
    private var isUser: Bool { message.role == .user }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(isUser ? "YOU" : "AGENT").tracking(1.5).foregroundStyle(isUser ? Console.muted : Console.blue)
                Rectangle().fill(Console.line).frame(height: 1)
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(message.content, forType: .string)
                } label: {
                    Label(copied ? "COPIED" : "COPY", systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.plain).foregroundStyle(Console.muted).help("Copy message")
            }.font(Console.mono(9, weight: .medium))
            if !isUser, let attribution = message.attribution {
                Text(attribution.label).font(Console.mono(9)).foregroundStyle(Console.muted).textSelection(.enabled)
                if attribution.startedNewThread {
                    Text("New runtime thread; visible history transferred.")
                        .font(Console.mono(9)).foregroundStyle(Console.amber)
                }
            }
            Text(message.content).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12).padding(.vertical, 5)
        .overlay(alignment: .leading) { Rectangle().fill(isUser ? Console.line : Console.blue.opacity(0.5)).frame(width: 2) }
        .accessibilityElement(children: .contain).accessibilityLabel(isUser ? "Your message" : "Assistant message")
    }
}
