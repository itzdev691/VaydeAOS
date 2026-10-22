import Combine
import Foundation

@MainActor
public final class ChatSession: ObservableObject {
    @Published public var draft = ""
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var settings: ConnectionSettings = .local
    @Published public private(set) var isSending = false
    @Published public private(set) var pendingMessage: ChatMessage?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var performanceHistory: [RequestPerformance] = []
    /// Monotonic start time; nil until client work actually starts.
    @Published public private(set) var performanceRequestStartedAt: TimeInterval?

    // Internal so tests can await the exact request, including a cancelled request.
    private(set) var sendTask: Task<Void, Never>?

    private let client: any ChatServing
    private let store: LocalStore
    private let credentials: any CredentialStoring
    private var activeRequest: ActiveRequest?
    private var settingsLoadIssue: String?
    private var messagesLoadIssue: String?
    // Never serialized. An empty value explicitly overrides a saved key.
    private var sessionAPIKeys: [String: String] = [:]

    private struct ActiveRequest {
        let id: UUID
        let originalDraft: String
        let message: ChatMessage
    }

    public init(
        client: any ChatServing = ChatClient(),
        store: LocalStore = LocalStore(),
        credentials: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.client = client
        self.store = store
        self.credentials = credentials

        do {
            if let saved = try store.loadSettings() {
                settings = try saved.validated()
            }
        } catch {
            settingsLoadIssue = "Could not load saved settings: \(error.localizedDescription) Open Connection and save your settings to replace the existing file."
        }

        do {
            messages = try store.loadMessages()
        } catch {
            messagesLoadIssue = "Could not load the saved conversation: \(error.localizedDescription) Start a New Chat to replace the existing file."
        }
        errorMessage = loadIssues
    }

    public var canSend: Bool {
        !isSending && activeRequest == nil && loadIssues == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func send() {
        guard canSend else { return }

        let request: ActiveRequest
        let connection: ConnectionSettings
        let apiKey: String?
        do {
            connection = try settings.validated()
            apiKey = try self.apiKey(for: connection)
            request = ActiveRequest(
                id: UUID(),
                originalDraft: draft,
                message: ChatMessage(role: .user, content: draft.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        } catch {
            errorMessage = "Could not send message: \(error.localizedDescription)"
            return
        }

        let conversation = messages + [request.message]
        activeRequest = request
        pendingMessage = request.message
        isSending = true
        draft = ""
        errorMessage = nil
        notice = nil

        sendTask = Task { [weak self, client] in
            do {
                try Task.checkCancellation()
                guard self?.activeRequest?.id == request.id else { return }
                self?.performanceRequestStartedAt = ProcessInfo.processInfo.systemUptime
                let response = try await client.measuredReply(to: conversation, settings: connection, apiKey: apiKey)
                if Task.isCancelled {
                    self?.finishCancellation(request.id)
                } else if response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.finishFailure(request.id, description: "The model returned an empty response.")
                } else {
                    self?.finishSuccess(request.id, response: response)
                }
            } catch is CancellationError {
                self?.finishCancellation(request.id)
            } catch let error as URLError where error.code == .cancelled {
                self?.finishCancellation(request.id)
            } catch {
                if Task.isCancelled {
                    self?.finishCancellation(request.id)
                } else {
                    self?.finishFailure(request.id, description: error.localizedDescription)
                }
            }
        }
    }

    public func stop() {
        guard let request = activeRequest else { return }
        sendTask?.cancel()
        recordPerformance(outcome: .cancelled)
        clearActiveRequest()
        draft = request.originalDraft
        errorMessage = nil
        notice = "Generation stopped. Your message is ready to send again."
    }

    public func newChat() {
        sendTask?.cancel()
        recordPerformance(outcome: .cancelled)
        clearActiveRequest()
        draft = ""
        messages = []
        messagesLoadIssue = nil
        errorMessage = settingsLoadIssue
        notice = nil
        do {
            try store.saveMessages(messages)
        } catch {
            errorMessage = "Could not clear the saved conversation: \(error.localizedDescription)"
        }
    }

    public func dismissError() {
        errorMessage = loadIssues
    }

    public func apiKey(for settings: ConnectionSettings) throws -> String? {
        let connection = try settings.validated()
        if let key = sessionAPIKeys[connection.baseURL] {
            return key.isEmpty ? nil : key
        }
        return try credentials.load(for: connection.baseURL)
    }

    public func usesSessionAPIKey(for settings: ConnectionSettings) -> Bool {
        guard let connection = try? settings.validated() else { return false }
        return sessionAPIKeys[connection.baseURL] != nil
    }

    public func saveSettings(
        _ settings: ConnectionSettings,
        apiKey: String,
        rememberAPIKey: Bool = true
    ) throws {
        notice = nil
        guard !isSending else { throw SessionError.requestInProgress }
        let connection = try settings.validated()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if rememberAPIKey {
            try credentials.save(key, for: connection.baseURL)
        }
        try store.saveSettings(connection)
        if rememberAPIKey {
            sessionAPIKeys.removeValue(forKey: connection.baseURL)
        } else {
            sessionAPIKeys[connection.baseURL] = key
        }
        if self.settings != connection { performanceHistory = [] }
        self.settings = connection
        settingsLoadIssue = nil
        errorMessage = messagesLoadIssue
        notice = rememberAPIKey
            ? "Settings saved."
            : "Settings saved. The API key is held only until you quit this app; existing Keychain entries are unchanged."
    }

    private var loadIssues: String? {
        let issues = [settingsLoadIssue, messagesLoadIssue].compactMap { $0 }
        return issues.isEmpty ? nil : issues.joined(separator: "\n\n")
    }

    private func finishSuccess(_ id: UUID, response: ChatReply) {
        guard let request = activeRequest, request.id == id else { return }
        messages.append(request.message)
        messages.append(ChatMessage(role: .assistant, content: response.content))
        recordPerformance(outcome: .success, reply: response)
        clearActiveRequest()
        do {
            try store.saveMessages(messages)
        } catch {
            errorMessage = "The reply was received, but the conversation could not be saved: \(error.localizedDescription)"
        }
    }

    private func finishFailure(_ id: UUID, description: String) {
        guard let request = activeRequest, request.id == id else { return }
        recordPerformance(outcome: .failed)
        clearActiveRequest()
        draft = request.originalDraft
        errorMessage = "Could not send message: \(description)"
    }

    private func finishCancellation(_ id: UUID) {
        guard let request = activeRequest, request.id == id else { return }
        recordPerformance(outcome: .cancelled)
        clearActiveRequest()
        draft = request.originalDraft
        errorMessage = nil
        notice = "Generation stopped. Your message is ready to send again."
    }

    private func recordPerformance(outcome: RequestPerformance.Outcome, reply: ChatReply? = nil) {
        guard let request = activeRequest, let start = performanceRequestStartedAt else { return }
        performanceHistory.append(RequestPerformance(id: request.id,
            elapsed: ProcessInfo.processInfo.systemUptime - start,
            inputTokens: reply?.inputTokens, outputTokens: reply?.outputTokens, outcome: outcome))
        if performanceHistory.count > 60 { performanceHistory.removeFirst(performanceHistory.count - 60) }
    }

    private func clearActiveRequest() {
        performanceRequestStartedAt = nil
        activeRequest = nil
        pendingMessage = nil
        isSending = false
        sendTask = nil
    }

    private enum SessionError: LocalizedError {
        case requestInProgress

        var errorDescription: String? {
            "Stop the current response before changing connection settings."
        }
    }
}
