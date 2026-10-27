import Combine
import Foundation

@MainActor
public final class ChatSession: ObservableObject {
    @Published public var draft = "" {
        didSet { scheduleDraftSave() }
    }
    @Published public private(set) var workspaces: [ChatWorkspace] = []
    @Published public private(set) var chats: [SavedChat] = []
    @Published public private(set) var selectedWorkspaceID: UUID
    @Published public private(set) var selectedChatID: UUID
    private var library: ChatLibrary
    private var libraryReady = false
    private var libraryLoadIssue: String?
    private var draftSaveTask: Task<Void, Never>?
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var settings: ConnectionSettings = .local
    @Published public private(set) var isSending = false
    @Published public private(set) var pendingMessage: ChatMessage?
    @Published public private(set) var partialReply = ""
    @Published public private(set) var interruptedTurns: [InterruptedTurn] = []
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
    public let codex: CodexRuntime
    public let apiModels: APIModelCatalog
    private var runtimeChanges: AnyCancellable?
    private var catalogChanges: AnyCancellable?
    @Published public private(set) var modelCatalogRevision = 0
    private var activeRequest: ActiveRequest?
    private var settingsLoadIssue: String?
    private var configurationLoadIssue: String?
    private var messagesLoadIssue: String?
    private var recoveryLoadIssue: String?
    // Never serialized. An empty value explicitly overrides a saved key.
    private var sessionAPIKeys: [String: String] = [:]

    private struct ActiveRequest {
        let id: UUID
        let originalDraft: String
        let message: ChatMessage
        let configuration: ConnectionSettings
    }

    public init(
        client: any ChatServing = ChatClient(),
        store: LocalStore = LocalStore(),
        credentials: any CredentialStoring = KeychainCredentialStore(),
        codex: CodexRuntime? = nil,
        apiModels: APIModelCatalog? = nil,
        legacyConsole: WorkspaceConsoleState? = nil
    ) {
        let initialLibrary = ChatLibrary(directory: "")
        library = initialLibrary
        selectedWorkspaceID = initialLibrary.selectedWorkspaceID
        selectedChatID = initialLibrary.chats[0].id
        self.client = client
        self.store = store
        self.credentials = credentials
        self.codex = codex ?? CodexRuntime(store: store)
        self.apiModels = apiModels ?? APIModelCatalog()
        var hasSavedLibrary = false

        do {
            if let saved = try store.loadSettings() {
                settings = try saved.validated()
            }
        } catch {
            settingsLoadIssue = "Could not load saved settings: \(error.localizedDescription) Open Connection and save this chat's settings to recover; the original file will be preserved."
        }

        do {
            if let saved = try store.load(ChatLibrary.self, from: "chat-library.json") {
                hasSavedLibrary = true
                library = try saved.validated()
                // Version 2 owns all chat settings; the old defaults file is no longer authoritative.
                if library.version == 2 { settingsLoadIssue = nil }
                if settingsLoadIssue == nil { library = library.migratingConfigurations(from: settings) }
                selectedWorkspaceID = library.selectedWorkspaceID
                let workspace = library.workspaces.first { $0.id == selectedWorkspaceID }!
                selectedChatID = workspace.selectedChatID
                let chat = library.chats.first { $0.id == selectedChatID }!
                settings = chat.configuration ?? settings
                messages = chat.messages
                interruptedTurns = chat.interruptedTurns
                draft = chat.draft
                if !interruptedTurns.isEmpty {
                    notice = "Interrupted conversation restored. Saved partial responses are incomplete; completed tool actions may remain."
                }
                settings.codexWorkspace = workspace.directory
                do { try self.codex.selectConversation(selectedChatID) }
                catch { recoveryLoadIssue = "Could not load this chat's task history. Start a New Chat or select another conversation. Saved files have been preserved." }
            } else {
                // Import without deleting or rewriting the original single-chat files.
                library.workspaces[0].directory = settings.codexWorkspace
                do { messages = try store.loadMessages() }
                catch { messagesLoadIssue = "Could not load the saved conversation: \(error.localizedDescription) Start a New Chat to recover; the original file will be preserved." }
                do {
                    interruptedTurns = try store.load([InterruptedTurn].self, from: "interrupted-turns.json") ?? []
                    if let last = interruptedTurns.last, last.afterMessageCount >= messages.count {
                        draft = last.originalDraft
                        notice = "Interrupted conversation restored. Saved partial responses are incomplete; completed tool actions may remain."
                    }
                } catch {
                    recoveryLoadIssue = "Could not load interrupted responses: \(error.localizedDescription) Start a New Chat to recover; the original file will be preserved."
                }
                do { try self.codex.selectConversation(selectedChatID, migrateLegacy: true) }
                catch { recoveryLoadIssue = "Could not load the previous task history. Start a New Chat to recover. The original file has been preserved." }
            }
        } catch {
            libraryLoadIssue = "Could not load the chat library: \(error.localizedDescription) The saved files have been preserved."
        }
        if libraryLoadIssue == nil, settingsLoadIssue == nil {
            library = library.migratingConfigurations(from: settings)
        }
        // The old console was global. Assign it once to the previously selected
        // workspace, while other legacy workspaces start with empty consoles.
        if libraryLoadIssue == nil {
            for index in library.workspaces.indices {
                if (!hasSavedLibrary || library.workspaces[index].needsConsoleMigration),
                   library.workspaces[index].id == selectedWorkspaceID, let legacyConsole {
                    library.workspaces[index].console = legacyConsole
                }
                library.workspaces[index].needsConsoleMigration = false
            }
        }
        validateCurrentConfiguration()
        snapshotCurrentChat()
        publishLibrary()
        libraryReady = true
        errorMessage = loadIssues
        if settings.needsChatGPTAccountReview {
            notice = "The ChatGPT connections were merged. Confirm the displayed account in Connection Settings before sending."
        }
        runtimeChanges = self.codex.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        catalogChanges = self.apiModels.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public var contextTransitionNotice: String? {
        var connection = settings
        connection.codexWorkspace = workspaceDirectory.path
        return codex.contextTransitionNotice(messages: messages, settings: connection)
    }

    public var modelSelection: ModelSelection {
        if settings.provider == .chatGPT {
            return ModelSelection(settings: settings, models: codex.modelOptions, catalogError: codex.modelCatalogError)
        }
        let state = apiModels.state(for: settings)
        return ModelSelection(settings: settings, models: state.models, catalogError: state.error)
    }
    public var isDiscoveringModels: Bool {
        settings.provider == .chatGPT ? codex.isChecking : apiModels.state(for: settings).isLoading
    }
    public var modelCatalogIdentity: String {
        "\(settings.provider.rawValue)\n\(settings.baseURL)\n\(modelCatalogRevision)"
    }
    public func refreshModels(force: Bool = false) async {
        guard !isSending else { return }
        let connection = settings
        if connection.provider == .chatGPT {
            if force || !codex.hasLoadedModels { await codex.refresh(settings: connection) }
        } else {
            var credentialScope = connection
            credentialScope.model = "discovery"
            do { await apiModels.refresh(settings: connection, apiKey: try apiKey(for: credentialScope), force: force) }
            catch { apiModels.reportError("Could not read this endpoint's API key. Open Connection Settings or use a session key.", for: connection) }
        }
    }

    public func selectModel(_ id: String) throws {
        guard canOrganizeChats, !isDiscoveringModels else { throw SessionError.requestInProgress }
        var connection = settings
        if connection.provider == .chatGPT { connection.chatGPTModel = id.isEmpty ? nil : id; connection.codexModel = id }
        else { connection.model = id }
        connection = try connection.validated()
        if let models = modelSelection.models,
           let issue = ModelSelection(settings: connection, models: models).modelIssue { throw ModelSelectionError(issue) }
        try persistConfiguration(connection)
    }

    public var canSend: Bool {
        !isSending && activeRequest == nil && loadIssues == nil
            && !isDiscoveringModels && modelSelection.issue == nil
            && (settings.provider != .chatGPT || (!codex.isRunning && !codex.isChecking
                && !settings.needsChatGPTAccountReview && (!codex.hasCheckedAccount || codex.isSignedIn)))
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func send() {
        guard canSend else { return }

        let request: ActiveRequest
        let connection: ConnectionSettings
        let apiKey: String?
        do {
            var selectedConnection = try settings.validated()
            if selectedConnection.provider == .chatGPT && selectedConnection.codexWorkspace.isEmpty {
                selectedConnection.codexWorkspace = workspaceDirectory.path
                try FileManager.default.createDirectory(atPath: selectedConnection.codexWorkspace,
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            connection = selectedConnection
            apiKey = try self.apiKey(for: connection)
            request = ActiveRequest(
                id: UUID(),
                originalDraft: draft,
                message: ChatMessage(role: .user, content: draft.trimmingCharacters(in: .whitespacesAndNewlines)),
                configuration: connection
            )
        } catch {
            errorMessage = "Could not send message: \(error.localizedDescription)"
            return
        }

        let conversation = messages + [request.message]
        activeRequest = request
        pendingMessage = request.message
        isSending = true
        partialReply = ""
        draft = ""
        errorMessage = nil
        notice = nil
        saveLibrary()

        sendTask = Task { [weak self, client] in
            do {
                try Task.checkCancellation()
                guard self?.activeRequest?.id == request.id else { return }
                self?.performanceRequestStartedAt = ProcessInfo.processInfo.systemUptime
                let response: ChatReply
                if connection.provider == .chatGPT {
                    guard let runtime = self?.codex else { return }
                    response = try await runtime.reply(to: conversation, settings: connection) { [weak self] text in
                        guard self?.activeRequest?.id == request.id else { return }
                        self?.partialReply = text
                    }
                } else {
                    response = try await client.measuredReply(to: conversation, settings: connection, apiKey: apiKey)
                }
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
        if settings.provider == .chatGPT { codex.cancel() }
        let recoveryError = preserveInterruptedTurn(request, wasCancelled: true)
        recordPerformance(outcome: .cancelled)
        clearActiveRequest()
        draft = request.originalDraft
        errorMessage = recoveryError
        notice = cancellationNotice
        saveLibrary()
    }

    public var selectedWorkspace: ChatWorkspace {
        workspaces.first { $0.id == selectedWorkspaceID }!
    }

    public var workspaceChats: [SavedChat] {
        chats.filter { $0.workspaceID == selectedWorkspaceID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The console and agent always describe the same effective task folder.
    public var workspaceDirectory: URL {
        let path = selectedWorkspace.directory
        return (path.isEmpty
            ? store.directory.appendingPathComponent("Workspaces/\(selectedWorkspaceID.uuidString)", isDirectory: true)
            : URL(fileURLWithPath: path, isDirectory: true)).resolvingSymlinksInPath()
    }

    public var workspaceConsole: WorkspaceConsoleState { selectedWorkspace.console }

    /// Select one project for the console and the agent without moving saved chats.
    public func selectWorkspaceProject(_ directory: String) throws {
        guard canOrganizeChats else { throw SessionError.requestInProgress }
        guard messagesLoadIssue == nil, recoveryLoadIssue == nil else { throw CocoaError(.fileReadCorruptFile) }
        let url = URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        snapshotCurrentChat()
        var next = library
        let index = next.workspaces.firstIndex { $0.id == selectedWorkspaceID }!
        next.workspaces[index].directory = url.path
        next.workspaces[index].console.projectDirectory = url.path
        next.workspaces[index].console.buildCommand = nil
        try store.save(next, to: "chat-library.json")
        library = next
        settings.codexWorkspace = url.path
        publishLibrary()
    }

    /// Console edits may happen during generation; snapshot the active prompt as well.
    public func updateWorkspaceConsole(_ update: (inout WorkspaceConsoleState) -> Void) {
        guard libraryLoadIssue == nil, messagesLoadIssue == nil, recoveryLoadIssue == nil else { return }
        snapshotCurrentChat()
        var next = library
        let index = next.workspaces.firstIndex { $0.id == selectedWorkspaceID }!
        update(&next.workspaces[index].console)
        do {
            try store.save(next, to: "chat-library.json")
            library = next
            publishLibrary()
        } catch { errorMessage = "Could not save workspace console: \(error.localizedDescription)" }
    }

    public var canOrganizeChats: Bool { libraryLoadIssue == nil && !isSending && !codex.isRunning && !codex.isChecking }

    public func newChat() {
        // New Chat preserves the old transcript. Stop a compatible request before archiving it.
        guard libraryLoadIssue == nil, !codex.isRunning, !codex.isChecking else { return }
        if isSending { stop() }
        guard saveLibrary(allowRecovery: true) else { return }
        let chat = SavedChat(id: UUID(), workspaceID: selectedWorkspaceID,
                             configuration: settingsLoadIssue == nil ? settings.chatConfiguration : nil)
        var next = library
        next.chats.append(chat)
        next.workspaces[next.workspaces.firstIndex { $0.id == selectedWorkspaceID }!].selectedChatID = chat.id
        commitSelection(next, chatID: chat.id)
    }

    public func selectChat(_ id: UUID) {
        guard canOrganizeChats, id != selectedChatID,
              let chat = library.chats.first(where: { $0.id == id && $0.workspaceID == selectedWorkspaceID }),
              saveLibrary(allowRecovery: true) else { return }
        var next = library
        next.workspaces[next.workspaces.firstIndex { $0.id == selectedWorkspaceID }!].selectedChatID = chat.id
        commitSelection(next, chatID: chat.id)
    }

    public func selectWorkspace(_ id: UUID) {
        guard canOrganizeChats, id != selectedWorkspaceID,
              let workspace = library.workspaces.first(where: { $0.id == id }), saveLibrary(allowRecovery: true) else { return }
        var next = library
        next.selectedWorkspaceID = id
        commitSelection(next, chatID: workspace.selectedChatID)
    }

    public func createWorkspace(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canOrganizeChats, !name.isEmpty, saveLibrary(allowRecovery: true) else { return }
        let id = UUID()
        let chat = SavedChat(id: UUID(), workspaceID: id,
                             configuration: settingsLoadIssue == nil ? settings.chatConfiguration : nil)
        var next = library
        next.workspaces.append(ChatWorkspace(id: id, name: name, directory: "", selectedChatID: chat.id))
        next.chats.append(chat)
        next.selectedWorkspaceID = id
        commitSelection(next, chatID: chat.id)
    }

    public func renameWorkspace(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canOrganizeChats, !name.isEmpty, let index = library.workspaces.firstIndex(where: { $0.id == id }) else { return }
        library.workspaces[index].name = name
        saveLibrary()
    }

    public func renameChat(_ id: UUID, to name: String) {
        guard canOrganizeChats, let index = library.chats.firstIndex(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        library.chats[index].name = name.isEmpty ? nil : name
        saveLibrary()
    }

    public func deleteChat(_ id: UUID) {
        guard canOrganizeChats, let chat = library.chats.first(where: { $0.id == id }),
              chat.workspaceID == selectedWorkspaceID, saveLibrary() else { return }
        var next = library
        next.chats.removeAll { $0.id == id }
        if id == selectedChatID {
            let replacement: SavedChat
            if let existing = next.chats.first(where: { $0.workspaceID == selectedWorkspaceID }) { replacement = existing }
            else {
                replacement = SavedChat(id: UUID(), workspaceID: selectedWorkspaceID,
                                        configuration: settingsLoadIssue == nil ? settings.chatConfiguration : nil)
                next.chats.append(replacement)
            }
            next.workspaces[next.workspaces.firstIndex { $0.id == selectedWorkspaceID }!].selectedChatID = replacement.id
            commitSelection(next, chatID: replacement.id)
        } else {
            do { try store.save(next, to: "chat-library.json"); library = next; publishLibrary() }
            catch { errorMessage = "Could not delete chat: \(error.localizedDescription)" }
        }
    }

    /// Flush on navigation and termination as well as after a short typing pause.
    public func saveDraft() { saveLibrary() }

    private func scheduleDraftSave() {
        guard libraryReady, messagesLoadIssue == nil, recoveryLoadIssue == nil else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000); try Task.checkCancellation() }
            catch { return }
            self?.saveLibrary()
        }
    }

    @discardableResult
    private func saveLibrary(allowRecovery: Bool = false) -> Bool {
        guard libraryLoadIssue == nil,
              allowRecovery || (messagesLoadIssue == nil && recoveryLoadIssue == nil) else { return false }
        draftSaveTask?.cancel()
        snapshotCurrentChat()
        publishLibrary()
        do { try store.save(library, to: "chat-library.json"); return true }
        catch { errorMessage = "Could not save the chat library: \(error.localizedDescription)"; return false }
    }

    private func snapshotCurrentChat() {
        guard let index = library.chats.firstIndex(where: { $0.id == selectedChatID }) else { return }
        let savedDraft = activeRequest?.originalDraft ?? draft
        let changed = library.chats[index].messages != messages || library.chats[index].draft != savedDraft
            || library.chats[index].interruptedTurns != interruptedTurns
        library.chats[index].messages = messages
        library.chats[index].draft = savedDraft
        library.chats[index].interruptedTurns = interruptedTurns
        if changed { library.chats[index].updatedAt = Date() }
    }

    private func publishLibrary() {
        workspaces = library.workspaces
        chats = library.chats
    }

    private func commitSelection(_ next: ChatLibrary, chatID: UUID) {
        let previousID = selectedChatID
        do {
            try codex.selectConversation(chatID)
            do { try store.save(next, to: "chat-library.json") }
            catch { try? codex.selectConversation(previousID); throw error }
            library = next
            selectedWorkspaceID = next.selectedWorkspaceID
            selectedChatID = chatID
            let chat = next.chats.first { $0.id == chatID }!
            draft = chat.draft
            messages = chat.messages
            interruptedTurns = chat.interruptedTurns
            settings = chat.configuration ?? settings
            settings.codexWorkspace = next.workspaces.first { $0.id == selectedWorkspaceID }!.directory
            validateCurrentConfiguration()
            messagesLoadIssue = nil
            recoveryLoadIssue = nil
            errorMessage = loadIssues
            notice = interruptedTurns.isEmpty ? nil
                : "Saved partial responses are incomplete; completed tool actions may remain."
            performanceHistory = []
            publishLibrary()
        } catch { errorMessage = "Could not open chat: \(error.localizedDescription)" }
    }

    public func dismissError() {
        errorMessage = loadIssues
    }

    public func apiKey(for settings: ConnectionSettings) throws -> String? {
        let connection = try settings.validated()
        guard connection.provider == .compatibleAPI else { return nil }
        if let key = sessionAPIKeys[connection.baseURL] {
            return key.isEmpty ? nil : key
        }
        return try credentials.load(for: connection.baseURL)
    }

    public func usesSessionAPIKey(for settings: ConnectionSettings) -> Bool {
        guard let connection = try? settings.validated() else { return false }
        return sessionAPIKeys[connection.baseURL] != nil
    }

    public func setReasoningEffort(_ effort: ConnectionSettings.ReasoningEffort) throws {
        guard !isSending, !codex.isRunning, !codex.isChecking else { throw SessionError.requestInProgress }
        // Explicit connection settings repair unreadable configuration; the slider cannot.
        guard settingsLoadIssue == nil, configurationLoadIssue == nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard effort != settings.reasoningEffort else { return }
        var connection = settings
        connection.reasoningEffort = effort
        if let issue = ModelSelection(settings: connection, models: modelSelection.models).issue {
            throw ModelSelectionError(issue)
        }
        try persistConfiguration(connection)
    }

    public func saveSettings(
        _ settings: ConnectionSettings,
        apiKey: String,
        rememberAPIKey: Bool = true
    ) throws {
        notice = nil
        guard !isSending, !codex.isRunning, !codex.isChecking else { throw SessionError.requestInProgress }
        var connection = try settings.validated()
        if connection.provider == .chatGPT {
            if connection.needsChatGPTAccountReview {
                guard codex.isSignedIn else { throw CodexRuntimeError.signInRequired }
                connection.needsChatGPTAccountReview = false
            }
            try persistConfiguration(connection)
            notice = "ChatGPT connection saved. Agent tools use the bundled runtime."
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if rememberAPIKey {
            try credentials.save(key, for: connection.baseURL)
        }
        try persistConfiguration(connection)
        if rememberAPIKey {
            sessionAPIKeys.removeValue(forKey: connection.baseURL)
        } else {
            sessionAPIKeys[connection.baseURL] = key
        }
        apiModels.invalidate(connection)
        modelCatalogRevision += 1
        notice = rememberAPIKey
            ? "Settings saved."
            : "Settings saved. The API key is held only until you quit this app; existing Keychain entries are unchanged."
    }

    /// Configuration and folder changes commit in the same atomic write as the transcript.
    /// Publish only after that write succeeds; settings.json remains an untouched migration source.
    private func persistConfiguration(_ connection: ConnectionSettings) throws {
        guard libraryLoadIssue == nil, messagesLoadIssue == nil, recoveryLoadIssue == nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var next = library.migratingConfigurations(from: connection)
        let chatIndex = next.chats.firstIndex { $0.id == selectedChatID }!
        let workspaceIndex = next.workspaces.firstIndex { $0.id == selectedWorkspaceID }!
        next.chats[chatIndex].messages = messages
        next.chats[chatIndex].draft = draft
        next.chats[chatIndex].interruptedTurns = interruptedTurns
        next.chats[chatIndex].configuration = connection.chatConfiguration
        next.workspaces[workspaceIndex].directory = connection.codexWorkspace
        try store.save(next, to: "chat-library.json")
        draftSaveTask?.cancel()
        library = next
        if settings != connection { performanceHistory = [] }
        settings = connection
        settingsLoadIssue = nil
        configurationLoadIssue = nil
        errorMessage = loadIssues
        publishLibrary()
    }

    private func validateCurrentConfiguration() {
        configurationLoadIssue = nil
        guard settingsLoadIssue == nil else { return }
        do { settings = try settings.validated() }
        catch {
            configurationLoadIssue = "Could not use this chat's connection settings: \(error.localizedDescription) Open Connection to repair this chat, or select another conversation."
        }
    }

    private var loadIssues: String? {
        let issues = [settingsLoadIssue, configurationLoadIssue, messagesLoadIssue, recoveryLoadIssue, libraryLoadIssue].compactMap { $0 }
        return issues.isEmpty ? nil : issues.joined(separator: "\n\n")
    }

    private func finishSuccess(_ id: UUID, response: ChatReply) {
        guard let request = activeRequest, request.id == id else { return }
        messages.append(request.message)
        let attribution = response.attribution ?? ResponseAttribution(provider: request.configuration.provider,
            model: request.configuration.activeModel, source: .requested)
        messages.append(ChatMessage(role: .assistant, content: response.content, attribution: attribution))
        recordPerformance(outcome: .success, reply: response)
        clearActiveRequest()
        if !saveLibrary() {
            errorMessage = "The reply was received, but the conversation could not be saved."
        }
    }

    private func finishFailure(_ id: UUID, description: String) {
        guard let request = activeRequest, request.id == id else { return }
        let recoveryError = preserveInterruptedTurn(request, wasCancelled: false)
        recordPerformance(outcome: .failed)
        clearActiveRequest()
        draft = request.originalDraft
        saveLibrary()
        let prefix = settings.provider == .chatGPT ? "Response interrupted" : "Could not send message"
        errorMessage = ["\(prefix): \(description)", recoveryError].compactMap { $0 }.joined(separator: "\n")
    }

    private func finishCancellation(_ id: UUID) {
        guard let request = activeRequest, request.id == id else { return }
        let recoveryError = preserveInterruptedTurn(request, wasCancelled: true)
        recordPerformance(outcome: .cancelled)
        clearActiveRequest()
        draft = request.originalDraft
        errorMessage = recoveryError
        notice = cancellationNotice
        saveLibrary()
    }

    private var cancellationNotice: String {
        settings.provider == .chatGPT
            ? "Codex stopped. Completed tool actions were not undone. Inspect activity before resending."
            : "Generation stopped. Your message is ready to send again."
    }

    private func preserveInterruptedTurn(_ request: ActiveRequest, wasCancelled: Bool) -> String? {
        guard settings.provider == .chatGPT, performanceRequestStartedAt != nil else { return nil }
        let response = partialReply.isEmpty ? nil : ChatMessage(role: .assistant, content: partialReply)
        interruptedTurns.append(InterruptedTurn(message: request.message, originalDraft: request.originalDraft,
            response: response, afterMessageCount: messages.count, wasCancelled: wasCancelled))
        return saveLibrary() ? nil : "The interrupted response is visible, but could not be saved."
    }

    private func recordPerformance(outcome: RequestPerformance.Outcome, reply: ChatReply? = nil) {
        guard let request = activeRequest, let start = performanceRequestStartedAt else { return }
        performanceHistory.append(RequestPerformance(id: request.id,
            elapsed: ProcessInfo.processInfo.systemUptime - start,
            inputTokens: reply?.inputTokens, outputTokens: reply?.outputTokens, outcome: outcome))
        if performanceHistory.count > 60 { performanceHistory.removeFirst(performanceHistory.count - 60) }
    }

    private func clearActiveRequest() {
        partialReply = ""
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
