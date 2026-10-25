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

    @Test func workspaceFolderFollowsSelectionAndGlobalConnectionStaysShared() throws {
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
    func reply(to messages: [ChatMessage], settings: ConnectionSettings, apiKey: String?) async throws -> String {
        requests.append(messages)
        return "Reply"
    }
}
