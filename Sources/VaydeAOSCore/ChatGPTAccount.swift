import Combine
import Foundation

@MainActor
public final class ChatGPTAccount: ObservableObject {
    @Published public private(set) var session: ChatGPTSessionState = .disconnected
    @Published public private(set) var profiles: [ChatGPTProfile] = []
    @Published public private(set) var models: [ChatGPTModel] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var canCancel = false
    @Published public private(set) var errorMessage: String?
    private let helper: any ChatGPTHelping
    private var operation: Task<Void, Never>?
    public static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    public init(helper: any ChatGPTHelping = ChatGPTHelper()) { self.helper = helper }

    public func refresh() { perform(ChatGPTHelperRequest(method: "state")) }

    public func signIn(newProfile: Bool = false, reconsent: Bool = false) {
        var request = ChatGPTHelperRequest(method: "signIn")
        request.newProfile = newProfile
        request.reconsent = reconsent
        if !newProfile { request.profileId = session.profileId }
        perform(request)
    }

    public func selectProfile(_ id: String) {
        var request = ChatGPTHelperRequest(method: profiles.first(where: { $0.id == id })?.pending == true ? "signIn" : "selectProfile")
        request.profileId = id
        perform(request)
    }

    public func disconnect() { perform(ChatGPTHelperRequest(method: "disconnect")) }
    public func cancel() { if canCancel { operation?.cancel() } }

    public func reply(to messages: [ChatMessage], model: String,
                      reasoningEffort: ConnectionSettings.ReasoningEffort = .automatic,
                      onDelta: @escaping @Sendable (String) -> Void) async throws -> ChatReply {
        guard !isBusy, session.canUsePlan else {
            throw ChatGPTHelperError(code: "sign_in_required", message: "Connect ChatGPT and authorize plan usage in Connection Settings.")
        }
        guard models.contains(where: { $0.slug == model }) else {
            throw ChatGPTHelperError(code: "model_not_found", message: "Refresh the available ChatGPT models in Connection Settings.")
        }
        var request = ChatGPTHelperRequest(method: "reply")
        request.model = model
        request.reasoningEffort = reasoningEffort.requestValue
        request.messages = messages
        let response = try await helper.request(request, onDelta: onDelta)
        try Task.checkCancellation()
        apply(response)
        if let error = response.error { throw error }
        guard let text = response.text else { throw ChatGPTHelperError.interrupted }
        return ChatReply(content: text)
    }

    public func shutdown() async {
        operation?.cancel()
        await helper.shutdown()
    }

    private func perform(_ request: ChatGPTHelperRequest) {
        guard !isBusy else { return }
        isBusy = true
        canCancel = request.method == "signIn" || request.method == "state"
        errorMessage = nil
        models = []
        operation = Task { [weak self, helper] in
            defer { self?.isBusy = false; self?.canCancel = false; self?.operation = nil }
            do {
                let response = try await helper.request(request, onDelta: nil)
                try Task.checkCancellation()
                self?.apply(response)
                if let error = response.error { throw error }
                try Task.checkCancellation()
                if self?.session.canUsePlan == true {
                    let catalog = try await helper.request(ChatGPTHelperRequest(method: "models"), onDelta: nil)
                    try Task.checkCancellation()
                    self?.apply(catalog)
                    if let error = catalog.error { throw error }
                }
            } catch is CancellationError {
                self?.errorMessage = "ChatGPT operation cancelled."
            } catch {
                if (error as? ChatGPTHelperError)?.code.hasPrefix("helper_") == true {
                    self?.session = .disconnected
                    self?.models = []
                }
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ response: ChatGPTHelperResponse) {
        if let session = response.session { self.session = session }
        if let profiles = response.profiles { self.profiles = profiles }
        if let models = response.models { self.models = models }
        if let error = response.error { errorMessage = error.message }
        else if let error = response.session?.error { errorMessage = error.message }
    }
}
