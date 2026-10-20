import SwiftUI
import VaydeAOSCore

struct ConnectionSettingsView: View {
    @ObservedObject var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var credentialEndpoint: String?
    @State private var endpointChanged = false
    @FocusState private var focusedField: Field?

    private let background = Console.background
    private let panel = Console.panel
    private let accent = Console.blue
    private let muted = Console.muted

    private enum Field: Hashable {
        case baseURL
        case model
        case apiKey
    }

    init(session: ChatSession) {
        self.session = session
        _baseURL = State(initialValue: session.settings.baseURL)
        _model = State(initialValue: session.settings.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("VAYDE AOS / SYSTEM CONFIG")
                    Spacer()
                    Image(systemName: "slider.horizontal.3")
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(accent)
                .padding(.bottom, 13)
                Text("Connection Settings")
                    .font(.system(size: 23, weight: .medium, design: .monospaced))
                Text("Choose the API and model used for this chat.")
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
            }

            Rectangle().fill(accent.opacity(0.23)).frame(height: 1)

            VStack(alignment: .leading, spacing: 18) {
                field("API base URL") {
                    TextField("http://127.0.0.1:11434/v1", text: $baseURL)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focusedField, equals: .baseURL)
                        .accessibilityLabel("API base URL")
                        .modifier(ConnectionInputStyle(accent: accent, panel: panel, focused: focusedField == .baseURL))
                        .onSubmit {
                            refreshCredentialForEndpoint()
                            focusedField = .model
                        }
                    Text("The app adds /chat/completions. Use HTTPS for a remote API or HTTP for a loopback address.")
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                field("Model") {
                    TextField("Model name", text: $model)
                        .focused($focusedField, equals: .model)
                        .accessibilityLabel("Model name")
                        .modifier(ConnectionInputStyle(accent: accent, panel: panel, focused: focusedField == .model))
                    Text("Enter the exact model identifier expected by the API.")
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                }

                field("API key") {
                    SecureField("Optional for a local server", text: apiKeyBinding)
                        .focused($focusedField, equals: .apiKey)
                        .accessibilityLabel("API key")
                        .modifier(ConnectionInputStyle(accent: accent, panel: panel, focused: focusedField == .apiKey))
                    Text(endpointChanged
                         ? "The endpoint changed. Enter its key if required. Keys are saved in macOS Keychain."
                         : "Required when your API uses authentication. Saved in macOS Keychain.")
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textFieldStyle(.plain)

            if let errorMessage {
                Label {
                    Text(errorMessage)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.system(size: 12))
                .foregroundStyle(Console.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .overlay(Rectangle().stroke(Color.red.opacity(0.3), lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Settings error: \(errorMessage)")
            }

            HStack {
                Button("Use Local Defaults") {
                    baseURL = ConnectionSettings.local.baseURL
                    model = ConnectionSettings.local.model
                }
                .buttonStyle(ConnectionButtonStyle(accent: accent))
                .help("Use the local Ollama API and default model")
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(ConnectionButtonStyle(accent: accent))
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                }
                .buttonStyle(ConnectionButtonStyle(accent: accent, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 560)
        .foregroundStyle(Console.text)
        .background(background)
        .overlay(alignment: .top) { Rectangle().fill(Console.brandGradient).frame(height: 2) }
        .tint(accent)
        .preferredColorScheme(.dark)
        .onAppear {
            refreshCredentialForEndpoint()
        }
        .onChange(of: baseURL) { _ in
            apiKey = ""
            credentialEndpoint = nil
            endpointChanged = true
            errorMessage = nil
        }
        .onChange(of: focusedField) { field in
            if field != .baseURL {
                refreshCredentialForEndpoint()
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(accent)
            content()
        }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { apiKey },
            set: { value in
                apiKey = value
                credentialEndpoint = try? ConnectionSettings(
                    baseURL: baseURL,
                    model: ConnectionSettings.local.model
                ).validated().baseURL
                errorMessage = nil
            }
        )
    }

    private func refreshCredentialForEndpoint() {
        do {
            let settings = try ConnectionSettings(
                baseURL: baseURL,
                model: ConnectionSettings.local.model
            ).validated()
            do {
                try loadCredentialIfNeeded(for: settings)
            } catch {
                errorMessage = "Could not read the saved API key: \(error.localizedDescription)"
            }
        } catch {
            apiKey = ""
            credentialEndpoint = nil
            errorMessage = error.localizedDescription
        }
    }

    private func loadCredentialIfNeeded(for settings: ConnectionSettings) throws {
        guard credentialEndpoint != settings.baseURL else { return }
        apiKey = ""
        apiKey = try session.apiKey(for: settings) ?? ""
        credentialEndpoint = settings.baseURL
        errorMessage = nil
    }

    private func save() {
        do {
            let settings = try ConnectionSettings(baseURL: baseURL, model: model).validated()
            try loadCredentialIfNeeded(for: settings)
            try session.saveSettings(settings, apiKey: apiKey)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ConnectionInputStyle: ViewModifier {
    let accent: Color
    let panel: Color
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(panel)
            .overlay(Rectangle().stroke((focused ? Console.red.opacity(0.85) : accent.opacity(0.22)), lineWidth: 1))
    }
}

private struct ConnectionButtonStyle: ButtonStyle {
    let accent: Color
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(primary ? Console.white : accent)
            .background(primary ? Console.blueStrong : Console.raised.opacity(configuration.isPressed ? 0.65 : 0.3))
            .overlay(Rectangle().stroke(accent.opacity(primary ? 1 : 0.3), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
    }
}
