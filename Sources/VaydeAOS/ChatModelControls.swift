import SwiftUI
import VaydeAOSCore

struct ChatModelControls: View {
    @ObservedObject var session: ChatSession
    let openSettings: () -> Void
    @State private var controlError: String?

    private var selection: ModelSelection { session.modelSelection }
    private var disabled: Bool { !session.canOrganizeChats || session.isDiscoveringModels }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("Model", selection: Binding(get: { selection.selectedID }, set: { id in
                    apply { try session.selectModel(id) }
                })) {
                    if session.settings.provider == .chatGPT {
                        Text(selection.models?.first(where: \.isDefault).map { "Account default: \($0.name)" }
                             ?? selection.models?.first.map { "Account default: \($0.name)" } ?? "Account default (unresolved)").tag("")
                    } else if selection.selectedID.isEmpty {
                        Text("Choose a model").tag("")
                    }
                    if !selection.selectedID.isEmpty && !(selection.models ?? []).contains(where: { $0.id == selection.selectedID }) {
                        Text(selection.selectedID + (selection.models == nil ? " (manual)" : " (not in catalog)"))
                            .tag(selection.selectedID)
                    }
                    ForEach(selection.models ?? []) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu).controlSize(.small).labelsHidden().accessibilityLabel("Model for this chat")
                .help(selection.resolvedModel?.id ?? selection.selectedID)
                .frame(maxWidth: .infinity, alignment: .leading).disabled(disabled)

                Picker("Reasoning", selection: Binding(get: { session.settings.reasoningEffort }, set: { effort in
                    apply { try session.setReasoningEffort(effort) }
                })) {
                    if !selection.availableEfforts.contains(session.settings.reasoningEffort) {
                        Text(session.settings.reasoningEffort.label + (selection.resolvedModel?.reasoningEfforts == nil ? " (unverified)" : " (unsupported)"))
                            .tag(session.settings.reasoningEffort)
                    }
                    ForEach(selection.availableEfforts, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).controlSize(.small).accessibilityLabel("Reasoning for this chat").disabled(disabled)

                Button { Task { await session.refreshModels(force: true) } } label: {
                    if session.isDiscoveringModels { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).disabled(disabled).help("Refresh models and capabilities")
                .accessibilityLabel("Refresh models")
                Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).disabled(disabled).help("Connection settings and manual model entry")
                    .accessibilityLabel("Model connection settings")
            }
            .font(Console.mono(10)).foregroundStyle(Console.blue)
            if let message = controlError ?? selection.issue {
                Text(message).foregroundStyle(Console.amber).font(Console.mono(10)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top) {
                Text(session.isDiscoveringModels ? "Refreshing model catalog…" : selection.hint)
                    .font(Console.mono(9)).foregroundStyle(Console.muted).fixedSize(horizontal: false, vertical: true)
                if session.settings.reasoningEffort != .automatic && !selection.availableEfforts.contains(session.settings.reasoningEffort) {
                    Button("Use Auto") { apply { try session.setReasoningEffort(.automatic) } }
                        .buttonStyle(.plain).font(Console.mono(9)).foregroundStyle(Console.blue).disabled(disabled)
                }
            }
        }
        .onChange(of: session.selectedChatID) { _ in controlError = nil }
    }

    private func apply(_ change: () throws -> Void) {
        do { try change(); controlError = nil }
        catch { controlError = error.localizedDescription }
    }
}
