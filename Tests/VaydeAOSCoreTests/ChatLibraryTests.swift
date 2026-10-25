import Foundation
import Testing
@testable import VaydeAOSCore

@MainActor
@Suite("Chats and workspaces")
final class ChatLibraryTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: directory) }
    private var store: LocalStore { LocalStore(directory: directory) }

    @Test func legacyHistoryAndRecoveryMigrateWithoutChangingOriginalFiles() throws {
        let history = [ChatMessage(role: .user, content: "Original question"), ChatMessage(role: .assistant, content: "Answer")]
        let attempt = InterruptedTurn(message: ChatMessage(role: .user, content: "Retry"), originalDraft: "  Retry\n",
                                      response: nil, afterMessageCount: 2, wasCancelled: true)
        try store.saveMessages(history)
        try store.save([attempt], to: "interrupted-turns.json")
        try store.save(CodexRecord(threadID: "legacy-thread"), to: "codex-session.json")
        let original = try Data(contentsOf: directory.appendingPathComponent("conversation.json"))
        let session = ChatSession(client: WorkspaceClient(), store: store)
        #expect(session.selectedWorkspace.name == "Personal")
        #expect(session.workspaceChats.first?.title == "Original question")
        #expect(session.messages == history)
        #expect(session.draft == "  Retry\n")
        #expect(session.codex.threadID == "legacy-thread")
        session.newChat()
        let restored = ChatSession(client: WorkspaceClient(), store: store)
        #expect(restored.chats.count == 2)
        restored.selectChat(session.chats.first { $0.messages == history }!.id)
        #expect(restored.interruptedTurns == [attempt])
        #expect(restored.draft == "  Retry\n")
        #expect(restored.codex.threadID == "legacy-thread")
        #expect(try Data(contentsOf: directory.appendingPathComponent("conversation.json")) == original)
    }

    @Test func chatsKeepSeparateContextDraftsAndSelectionAcrossWorkspacesAndRelaunch() async throws {
        let client = WorkspaceClient()
        let session = ChatSession(client: client, store: store)
        let personal = session.selectedWorkspaceID
        let first = session.selectedChatID
        session.draft = "First context"; session.send(); await session.sendTask?.value
        session.draft = "Unsent first draft"
        session.newChat()
        let second = session.selectedChatID
        session.draft = "Second context"; session.send(); await session.sendTask?.value
        session.renameChat(second, to: "Second chat")
        session.createWorkspace(named: "Engineering")
        let engineering = session.selectedWorkspaceID
        let third = session.selectedChatID
        session.draft = "Third context"; session.send(); await session.sendTask?.value
        session.draft = "Unsent engineering draft"
        session.selectWorkspace(personal)
        #expect(session.selectedChatID == second)
        #expect(session.workspaceChats.count == 2)
        session.selectChat(first)
        #expect(session.draft == "Unsent first draft")
        session.draft = "Follow up"; session.send(); await session.sendTask?.value
        let requests = await client.requests
        #expect(requests.map { $0.map(\.content) } == [
            ["First context"], ["Second context"], ["Third context"], ["First context", "Reply", "Follow up"]
        ])
        session.selectWorkspace(engineering)
        session.saveDraft()
        let restored = ChatSession(client: client, store: store)
        #expect(restored.selectedWorkspaceID == engineering)
        #expect(restored.selectedChatID == third)
        #expect(restored.draft == "Unsent engineering draft")
        #expect(restored.workspaceChats.count == 1)
        restored.selectWorkspace(personal)
        #expect(restored.selectedChatID == first)
        #expect(restored.chats.first { $0.id == second }?.title == "Second chat")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("chat-library.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func workspaceFolderFollowsSelectionAndNewWorkspaceInheritsConnection() throws {
        let session = ChatSession(client: WorkspaceClient(), store: store)
        var settings = ConnectionSettings.local
        settings.codexWorkspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        try session.saveSettings(settings, apiKey: "")
        let personal = session.selectedWorkspaceID
        session.createWorkspace(named: "Other")
        #expect(session.settings.codexWorkspace.isEmpty)
        #expect(session.settings.model == settings.model)
        session.selectWorkspace(personal)
        #expect(session.settings.codexWorkspace == settings.codexWorkspace)
        let restored = ChatSession(client: WorkspaceClient(), store: store)
        #expect(restored.settings.codexWorkspace == settings.codexWorkspace)
    }

    @Test func chatsRestoreTheirOwnConnectionsAndSendWithThemAfterRelaunch() async throws {
        let client = WorkspaceClient()
        let session = ChatSession(client: client, store: store)
        let first = session.selectedChatID
        let firstSettings = ConnectionSettings(baseURL: "https://first.example/v1", model: "first-model", reasoningEffort: .low)
        try session.saveSettings(firstSettings, apiKey: "first-secret", rememberAPIKey: false)
        session.draft = "First draft"
        session.newChat()
        let second = session.selectedChatID
        #expect(session.settings == firstSettings)
        let secondSettings = ConnectionSettings(baseURL: "https://second.example/v1", model: "second-model", reasoningEffort: .high)
        try session.saveSettings(secondSettings, apiKey: "second-secret", rememberAPIKey: false)
        session.draft = "Second draft"
        session.selectChat(first)
        #expect(session.settings == firstSettings)
        #expect(session.draft == "First draft")
        #expect(try session.apiKey(for: session.settings) == "first-secret")
        session.send(); await session.sendTask?.value
        session.selectChat(second)
        #expect(session.settings == secondSettings)
        #expect(session.draft == "Second draft")
        #expect(try session.apiKey(for: session.settings) == "second-secret")
        session.send(); await session.sendTask?.value
        #expect(await client.connections == [firstSettings, secondSettings])

        let restored = ChatSession(client: client, store: store)
        #expect(restored.selectedChatID == second)
        #expect(restored.settings == secondSettings)
        restored.selectChat(first)
        #expect(restored.settings == firstSettings)
        restored.draft = "Relaunched follow-up"; restored.send(); await restored.sendTask?.value
        #expect(await client.connections.last == firstSettings)
        let encoded = try String(contentsOf: directory.appendingPathComponent("chat-library.json"), encoding: .utf8)
        #expect(!encoded.contains("first-secret"))
        #expect(!encoded.contains("second-secret"))
    }

    @Test func providerAndWorkspaceSettingsStaySeparateAcrossChats() throws {
        let session = ChatSession(client: WorkspaceClient(), store: store)
        let personal = session.selectedWorkspaceID
        let first = session.selectedChatID
        session.newChat()
        let second = session.selectedChatID
        var chatGPT = ConnectionSettings(baseURL: "", model: "", provider: .chatGPT,
                                         chatGPTModel: "chat-model", reasoningEffort: .medium)
        chatGPT.codexWorkspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        try session.saveSettings(chatGPT, apiKey: "ignored")
        session.selectChat(first)
        #expect(session.settings.provider == .compatibleAPI)
        #expect(session.settings.codexWorkspace == chatGPT.codexWorkspace)
        try session.setReasoningEffort(.minimal)
        session.createWorkspace(named: "Other")
        #expect(session.settings.provider == .compatibleAPI)
        #expect(session.settings.reasoningEffort == .minimal)
        #expect(session.settings.codexWorkspace.isEmpty)
        session.selectWorkspace(personal)
        session.selectChat(second)
        #expect(session.settings.provider == .chatGPT)
        #expect(session.settings.activeModel == "chat-model")
        #expect(session.settings.reasoningEffort == .medium)
        let restored = ChatSession(client: WorkspaceClient(), store: store)
        #expect(restored.settings == session.settings)
        restored.selectChat(first)
        #expect(restored.settings.reasoningEffort == .minimal)
    }

    @Test func newWorkspaceCanInheritLegacyChatGPTSettingsWithoutItsOldFolder() throws {
        let session = ChatSession(client: WorkspaceClient(), store: store)
        let connection = ConnectionSettings(baseURL: "", model: "", provider: .chatGPT,
            chatGPTModel: "legacy-model", reasoningEffort: .high,
            codexWorkspace: FileManager.default.temporaryDirectory.path, codexAllowsWrites: true)
        try session.saveSettings(connection, apiKey: "")
        session.createWorkspace(named: "New project")
        #expect(session.settings.codexWorkspace.isEmpty)
        #expect(session.settings.activeModel == "legacy-model")
        #expect(session.settings.reasoningEffort == .high)
        #expect(session.errorMessage == nil)
        session.draft = "A new task"
        #expect(session.canSend)
        let restored = ChatSession(client: WorkspaceClient(), store: store)
        #expect(restored.settings.codexWorkspace.isEmpty)
        #expect(restored.settings.activeModel == "legacy-model")
        #expect(restored.errorMessage == nil)
    }

    @Test func legacyLibrarySeedsEveryChatBeforeTheFirstConfigurationEdit() throws {
        var legacy = ChatLibrary(directory: "")
        let first = legacy.chats[0].id
        let second = SavedChat(id: UUID(), workspaceID: legacy.selectedWorkspaceID,
                               messages: [ChatMessage(role: .user, content: "Keep this history")], draft: "Keep this draft")
        legacy.chats.append(second)
        try store.save(legacy, to: "chat-library.json")
        let defaults = ConnectionSettings(baseURL: "https://legacy.example/v1", model: "legacy-model", reasoningEffort: .high)
        try store.saveSettings(defaults)
        let originalDefaults = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        let originalLibrary = try Data(contentsOf: directory.appendingPathComponent("chat-library.json"))
        let session = ChatSession(client: WorkspaceClient(), store: store)
        #expect(session.settings == defaults)
        #expect(try Data(contentsOf: directory.appendingPathComponent("chat-library.json")) == originalLibrary)
        var edited = defaults; edited.model = "changed-model"
        try session.saveSettings(edited, apiKey: "", rememberAPIKey: false)
        session.selectChat(second.id)
        #expect(session.settings == defaults)
        #expect(session.messages == second.messages)
        #expect(session.draft == second.draft)
        let upgraded = try #require(try store.load(ChatLibrary.self, from: "chat-library.json"))
        #expect(upgraded.version == 2)
        #expect(upgraded.chats.allSatisfy { $0.configuration != nil })
        #expect(try Data(contentsOf: directory.appendingPathComponent("settings.json")) == originalDefaults)
        let restored = ChatSession(client: WorkspaceClient(), store: store)
        #expect(restored.settings == defaults)
        restored.selectChat(first)
        #expect(restored.settings == edited)
    }

    @Test func configuredLibraryDoesNotDependOnLegacyDefaults() throws {
        let session = ChatSession(client: WorkspaceClient(), store: store)
        var connection = ConnectionSettings.local; connection.model = "saved-model"
        try session.saveSettings(connection, apiKey: "", rememberAPIKey: false)
        try Data("unreadable legacy defaults".utf8).write(to: directory.appendingPathComponent("settings.json"))
        let restored = ChatSession(client: WorkspaceClient(), store: store)
        #expect(restored.settings == connection)
        #expect(restored.errorMessage == nil)
        restored.draft = "Continue"
        #expect(restored.canSend)
    }

    @Test func failedConfigurationWriteDoesNotChangeActiveSettingsOrWorkspace() throws {
        let session = ChatSession(client: WorkspaceClient(), store: store)
        try session.saveSettings(.local, apiKey: "", rememberAPIKey: false)
        session.draft = "Keep draft"
        let before = session.chats
        let url = directory.appendingPathComponent("chat-library.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("prevent replacement".utf8).write(to: url.appendingPathComponent("blocker"))
        var changed = ConnectionSettings.local
        changed.model = "unsaved-model"
        changed.codexWorkspace = FileManager.default.temporaryDirectory.path
        #expect(throws: (any Error).self) { try session.saveSettings(changed, apiKey: "", rememberAPIKey: false) }
        #expect(session.settings == .local)
        #expect(session.selectedWorkspace.directory.isEmpty)
        #expect(session.chats == before)
        #expect(session.draft == "Keep draft")
        #expect(session.notice == nil)
        #expect(throws: (any Error).self) { try session.setReasoningEffort(.high) }
        #expect(session.settings.reasoningEffort == .automatic)
    }

    @Test func missingConfigurationInVersionTwoIsRejectedWithoutOverwritingLibrary() throws {
        var invalid = ChatLibrary(directory: "")
        invalid.version = 2
        try store.save(invalid, to: "chat-library.json")
        let url = directory.appendingPathComponent("chat-library.json")
        let original = try Data(contentsOf: url)
        let session = ChatSession(client: WorkspaceClient(), store: store)
        #expect(!session.canOrganizeChats)
        #expect(throws: (any Error).self) { try session.saveSettings(.local, apiKey: "", rememberAPIKey: false) }
        session.saveDraft()
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func invalidChatConfigurationCanBeRepairedWithoutBlockingOtherChats() throws {
        var library = ChatLibrary(directory: "").migratingConfigurations(from: .local)
        let invalidID = library.chats[0].id
        library.chats[0].configuration?.model = ""
        let valid = SavedChat(id: UUID(), workspaceID: library.selectedWorkspaceID, configuration: .local)
        library.chats.append(valid)
        try store.save(library, to: "chat-library.json")
        let session = ChatSession(client: WorkspaceClient(), store: store)
        session.draft = "Do not send with invalid settings"
        #expect(!session.canSend)
        #expect(session.canOrganizeChats)
        #expect(session.errorMessage?.contains("this chat's connection settings") == true)
        session.selectChat(valid.id)
        session.draft = "Valid settings"
        #expect(session.canSend)
        #expect(session.errorMessage == nil)
        session.selectChat(invalidID)
        #expect(!session.canSend)
        try session.saveSettings(.local, apiKey: "", rememberAPIKey: false)
        #expect(session.canSend)
        #expect(ChatSession(client: WorkspaceClient(), store: store).errorMessage == nil)
    }

    @Test func credentialsRemainSharedByEndpointWhileModelsStayPerChat() throws {
        let credentials = WorkspaceCredentials()
        let session = ChatSession(client: WorkspaceClient(), store: store, credentials: credentials)
        let first = session.selectedChatID
        let endpoint = "https://shared.example/v1"
        let firstSettings = ConnectionSettings(baseURL: endpoint, model: "first-model")
        try session.saveSettings(firstSettings, apiKey: "shared-secret")
        session.newChat()
        var secondSettings = firstSettings; secondSettings.model = "second-model"
        try session.saveSettings(secondSettings, apiKey: "updated-secret")
        session.selectChat(first)
        #expect(session.settings.model == "first-model")
        #expect(try session.apiKey(for: session.settings) == "updated-secret")
        let restored = ChatSession(client: WorkspaceClient(), store: store, credentials: credentials)
        #expect(restored.settings.model == "first-model")
        #expect(try restored.apiKey(for: restored.settings) == "updated-secret")
        let encoded = try String(contentsOf: directory.appendingPathComponent("chat-library.json"), encoding: .utf8)
        #expect(!encoded.contains("shared-secret"))
        #expect(!encoded.contains("updated-secret"))
    }

    @Test func corruptLibraryNeverOverwritesFilesOrFallsBackToLegacyHistory() throws {
        try store.saveMessages([ChatMessage(role: .user, content: "Obsolete legacy chat")])
        let url = directory.appendingPathComponent("chat-library.json")
        let invalid = Data("invalid library".utf8)
        try invalid.write(to: url)
        let session = ChatSession(client: WorkspaceClient(), store: store)
        session.draft = "Do not persist"
        session.saveDraft(); session.newChat(); session.createWorkspace(named: "No")
        #expect(!session.canSend)
        #expect(!session.canOrganizeChats)
        #expect(session.messages.isEmpty)
        #expect(session.errorMessage != nil)
        #expect(try Data(contentsOf: url) == invalid)
    }

    @Test func invalidMembershipIsRejectedAndDeletingLastChatKeepsWorkspaceUsable() throws {
        var invalid = ChatLibrary(directory: "")
        invalid.workspaces[0].selectedChatID = UUID()
        #expect(throws: (any Error).self) { try invalid.validated() }
        let session = ChatSession(client: WorkspaceClient(), store: store)
        let first = session.selectedChatID
        session.renameWorkspace(session.selectedWorkspaceID, to: "Research")
        session.renameChat(first, to: "Named chat")
        #expect(session.workspaceChats.first?.title == "Named chat")
        session.deleteChat(first)
        #expect(session.selectedChatID != first)
        #expect(session.workspaceChats.count == 1)
        #expect(session.selectedWorkspace.name == "Research")
        session.draft = "Still usable"
        #expect(session.canSend)
    }

    @Test func failedSelectionWriteLeavesOriginalChatAndDraftActive() throws {
        let session = ChatSession(client: WorkspaceClient(), store: store)
        session.newChat()
        let active = session.selectedChatID
        let other = session.chats.first { $0.id != active }!.id
        session.draft = "Keep in memory"
        try FileManager.default.removeItem(at: directory)
        try Data("blocks storage".utf8).write(to: directory)
        session.selectChat(other)
        #expect(session.selectedChatID == active)
        #expect(session.draft == "Keep in memory")
        #expect(session.errorMessage != nil)
    }
}

private actor WorkspaceClient: ChatServing {
    var requests: [[ChatMessage]] = []
    var connections: [ConnectionSettings] = []
    func reply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> String {
        requests.append(messages)
        connections.append(settings)
        return "Reply"
    }
}

private final class WorkspaceCredentials: CredentialStoring {
    private var values: [String: String] = [:]
    func load(for endpoint: String) throws -> String? { values[endpoint] }
    func save(_ key: String, for endpoint: String) throws { values[endpoint] = key.isEmpty ? nil : key }
}
