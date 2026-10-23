import SwiftUI
import VaydeAOSCore

struct ChatGPTAccountView: View {
    @ObservedObject var account: ChatGPTAccount
    @Binding var model: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CONNECT YOUR CHATGPT PLAN")
                .font(Console.mono(10, weight: .semibold)).tracking(1.2).foregroundStyle(Console.blue)
            Text("Authorize VaydeAOS to use your eligible ChatGPT plan. Requests run through OpenAI and count toward your plan's usage limits.")
                .font(.system(size: 12)).foregroundStyle(Console.muted).fixedSize(horizontal: false, vertical: true)

            if !account.profiles.isEmpty {
                Picker("Saved connection", selection: Binding(
                    get: { account.session.profileId ?? "" },
                    set: { account.selectProfile($0) })) {
                    Text("Choose account").tag("")
                    ForEach(account.profiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }.disabled(account.isBusy)
            }

            HStack {
                Label(account.session.canUsePlan ? "Using ChatGPT plan" : account.session.status == "connected"
                    ? "Signed in · plan usage disabled" : "ChatGPT disconnected", systemImage: account.session.canUsePlan ? "checkmark.circle" : "person.crop.circle")
                    .font(Console.mono(11)).foregroundStyle(account.session.canUsePlan ? Console.green : Console.muted)
                Spacer()
                Link("Manage usage", destination: ChatGPTAccount.usageURL).font(Console.mono(11))
            }

            if account.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Completing ChatGPT connection…").font(Console.mono(11))
                    Spacer()
                    if account.canCancel { Button("Stop") { account.cancel() } }
                }
            } else {
                HStack {
                    Button(account.session.status == "connected" ? "Reconnect" : "Continue with ChatGPT") {
                        account.signIn()
                    }
                    if account.session.status == "connected" && !account.session.sharing {
                        Button("Enable plan usage") { account.signIn(reconsent: true) }
                    }
                    if !account.profiles.isEmpty {
                        Button("Add account") { account.signIn(newProfile: true) }
                        Button("Sign out") { account.disconnect() }
                    }
                }
                .buttonStyle(.bordered)
            }

            if account.session.canUsePlan {
                Picker("Model", selection: $model) {
                    Text("Choose model").tag("")
                    ForEach(account.models) { item in Text(item.displayName).tag(item.slug) }
                }
                .disabled(account.isBusy)
                Button("Refresh models") { account.refresh() }.disabled(account.isBusy)
                if !account.isBusy && account.models.isEmpty && account.errorMessage == nil {
                    Text("No models are available for this connection.").font(Console.mono(11)).foregroundStyle(Console.amber)
                }
            }
            if let error = account.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(Console.amber)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text("Account sign-in and plan authorization are separate. This connection does not import your ChatGPT conversations.")
                .font(.system(size: 11)).foregroundStyle(Console.muted).fixedSize(horizontal: false, vertical: true)
        }
        .task { account.refresh() }
        .onChange(of: account.models) { models in
            guard !models.isEmpty else { return }
            if !models.contains(where: { $0.slug == model }) { model = models.first?.slug ?? "" }
        }
    }
}
