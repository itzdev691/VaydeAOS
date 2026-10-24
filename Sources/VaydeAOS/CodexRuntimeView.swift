import AppKit
import SwiftUI
import VaydeAOSCore

struct ChatGPTConnectionView: View {
    @ObservedObject var runtime: CodexRuntime
    @Binding var model: String
    @Binding var workspace: String
    @Binding var allowsWrites: Bool
    let settings: ConnectionSettings
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CHATGPT ACCOUNT").font(Console.mono(10)).foregroundStyle(Console.blue)
                Spacer()
                if runtime.isChecking { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await runtime.refresh(settings: settings) } }
                    .disabled(runtime.isChecking || runtime.isRunning)
            }
            Text(runtime.accountDescription).font(Console.mono(11)).textSelection(.enabled)
            HStack {
                Button(runtime.loginPending ? "Cancel sign-in" : "Continue with ChatGPT") {
                    Task {
                        if runtime.loginPending { await runtime.cancelLogin(); return }
                        do { NSWorkspace.shared.open(try await runtime.signIn()) }
                        catch { loginError = error.localizedDescription }
                    }
                }.disabled(runtime.isRunning || runtime.isChecking)
                Text("One account for conversation and agent tools.")
                    .font(.system(size: 11)).foregroundStyle(Console.muted)
            }
            HStack {
                Link("Manage usage", destination: ChatGPTAccount.usageURL)
                Spacer()
                if runtime.isSignedIn {
                    Button("Sign out") {
                        Task {
                            do { try await runtime.signOut() }
                            catch { loginError = error.localizedDescription }
                        }
                    }.disabled(runtime.isRunning || runtime.isChecking)
                }
            }.font(Console.mono(11))
            Text("This ChatGPT connection is shared with Codex on this Mac. Signing out disconnects that shared account.")
                .font(.system(size: 11)).foregroundStyle(Console.muted).fixedSize(horizontal: false, vertical: true)
            Picker("Model", selection: $model) {
                Text("Use account default").tag("")
                if !model.isEmpty && !runtime.models.contains(where: { $0.id == model }) {
                    Text(model + " (not in current catalog)").tag(model)
                }
                ForEach(runtime.models) { Text($0.name).tag($0.id) }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Workspace folder (optional)").font(Console.mono(10)).foregroundStyle(Console.blue)
                    Text(workspace.isEmpty ? "Private read-only chat workspace" : workspace)
                        .font(Console.mono(11)).textSelection(.enabled).lineLimit(3)
                }
                Spacer()
                Button("Choose…") {
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = true; picker.canChooseFiles = false
                    picker.allowsMultipleSelection = false; picker.prompt = "Use Workspace"
                    if !workspace.isEmpty { picker.directoryURL = URL(fileURLWithPath: workspace) }
                    if picker.runModal() == .OK, let url = picker.url { workspace = url.resolvingSymlinksInPath().path }
                }
            }
            Toggle("Allow shell and file writes in this workspace", isOn: $allowsWrites)
                .font(.system(size: 12))
                .disabled(workspace.isEmpty)
            Text("Shell access starts read only. Commands can request approval. MCP services use their own account scopes and are not confined by the shell sandbox. Stop does not undo completed actions.")
                .font(.system(size: 11)).foregroundStyle(Console.muted).fixedSize(horizontal: false, vertical: true)
            if !runtime.integrations.isEmpty {
                DisclosureGroup("Integrations (\(runtime.integrations.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(runtime.integrations) { integration in
                                HStack {
                                    Text(integration.name).lineLimit(1)
                                    Spacer()
                                    Text(integration.state)
                                    if let count = integration.toolCount { Text("\(count) tools") }
                                }.font(Console.mono(10))
                            }
                        }
                    }.frame(maxHeight: 110)
                }
            }
            if let error = loginError ?? runtime.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(Console.amber).textSelection(.enabled)
            }
        }
        .task { await runtime.refresh(settings: settings) }
        .onDisappear { Task { await runtime.cancelLogin() } }
    }
}

struct CodexTaskView: View {
    @ObservedObject var runtime: CodexRuntime
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !runtime.activity.isEmpty {
                DisclosureGroup("Tool activity (\(runtime.activity.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(runtime.activity) { event in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .top) {
                                        Text(event.title).textSelection(.enabled)
                                        Spacer()
                                        Text(event.status).foregroundStyle(event.status == "failed" ? Console.amber : Console.muted)
                                    }.font(Console.mono(10))
                                    if !event.detail.isEmpty {
                                        DisclosureGroup("Details") {
                                            Text(event.detail).font(Console.mono(10)).textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }.font(Console.mono(10))
                                    }
                                }
                            }
                        }
                    }.frame(maxHeight: 180)
                }.font(Console.mono(11)).foregroundStyle(Console.blue)
            }
            ForEach(runtime.prompts) { prompt in
                CodexPromptView(runtime: runtime, prompt: prompt)
            }
            if let error = runtime.errorMessage {
                Text(error).font(Console.mono(10)).foregroundStyle(Console.amber).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodexPromptView: View {
    @ObservedObject var runtime: CodexRuntime
    let prompt: CodexPrompt
    @State private var answers: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.title).font(Console.mono(12, weight: .semibold))
            if !prompt.detail.isEmpty {
                ScrollView { Text(prompt.detail).font(Console.mono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180)
            }
            ForEach(prompt.questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    ForEach(question.options, id: \.self) { option in
                        Button(option) { answers[question.id] = option }
                            .buttonStyle(ConsoleButtonStyle(prominent: answers[question.id] == option))
                    }
                    if question.isSecret {
                        SecureField("Answer", text: binding(question.id)).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Answer", text: binding(question.id)).textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Button("Stop task") { runtime.cancel() }
                Spacer()
                if prompt.questions.isEmpty {
                    Button("Decline") { runtime.answer(prompt, approve: false) }
                        .buttonStyle(ConsoleButtonStyle())
                    Button("Allow once") { runtime.answer(prompt, approve: true) }
                        .buttonStyle(ConsoleButtonStyle(prominent: true)).disabled(!prompt.canApprove)
                } else {
                    Button("Submit answers") { runtime.answer(prompt, answers: answers) }
                        .buttonStyle(ConsoleButtonStyle(prominent: true))
                        .disabled(prompt.questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }.font(Console.mono(10))
        }
        .padding(12).background(Console.amber.opacity(0.08))
        .overlay(Rectangle().stroke(Console.amber.opacity(0.4)))
        .accessibilityElement(children: .contain)
    }
    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
}
