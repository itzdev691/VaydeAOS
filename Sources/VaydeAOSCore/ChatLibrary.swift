import Foundation

public struct ChatWorkspace: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var directory: String
    public var selectedChatID: UUID
}

public struct SavedChat: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public var name: String?
    public var messages: [ChatMessage] = []
    public var interruptedTurns: [InterruptedTurn] = []
    public var draft = ""
    public var updatedAt = Date()

    public var title: String {
        if let name, !name.isEmpty { return name }
        let prompt = messages.first(where: { $0.role == .user })?.content
            ?? interruptedTurns.first?.message.content
        return prompt.map { String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60)) } ?? "New chat"
    }
}

/// A single atomic index owns membership, selected chats, transcripts, and drafts.
/// Runtime audit records live separately under each chat's UUID.
struct ChatLibrary: Codable {
    var version = 1
    var workspaces: [ChatWorkspace]
    var chats: [SavedChat]
    var selectedWorkspaceID: UUID

    init(directory: String) {
        let workspaceID = UUID()
        let chatID = UUID()
        workspaces = [ChatWorkspace(id: workspaceID, name: "Personal", directory: directory, selectedChatID: chatID)]
        chats = [SavedChat(id: chatID, workspaceID: workspaceID)]
        selectedWorkspaceID = workspaceID
    }

    func validated() throws -> Self {
        guard version == 1, !workspaces.isEmpty,
              Set(workspaces.map(\.id)).count == workspaces.count,
              Set(chats.map(\.id)).count == chats.count,
              workspaces.contains(where: { $0.id == selectedWorkspaceID }),
              workspaces.allSatisfy({ workspace in
                  !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && chats.contains(where: { $0.id == workspace.selectedChatID && $0.workspaceID == workspace.id })
              }),
              chats.allSatisfy({ chat in workspaces.contains(where: { $0.id == chat.workspaceID }) })
        else { throw CocoaError(.fileReadCorruptFile) }
        return self
    }
}
