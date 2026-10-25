import SwiftUI
import VaydeAOSCore

struct ChatSidebar: View {
    @ObservedObject var session: ChatSession
    let openChat: () -> Void
    let openConsole: () -> Void
    let isChatOpen: Bool
    @State private var search = ""
    @State private var renaming: SavedChat?
    @State private var deleting: SavedChat?
    @State private var editingWorkspace: ChatWorkspace?
    @State private var creatingWorkspace = false
    @State private var name = ""

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                newChat(in: session.selectedWorkspace)
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ChatSidebarRowStyle()).padding(.bottom, 10)
            .disabled(!session.canOrganizeChats)
            .accessibilityLabel("New chat in workspace")
            .help("New chat in \(session.selectedWorkspace.name) (Command-N)")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Console.muted)
                TextField("Search this workspace", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search chats in the current workspace")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Console.muted)
                        .accessibilityLabel("Clear chat search")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 8)
            .background(Console.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(.bottom, 20)

            HStack {
                Text("Workspaces").font(.system(size: 11, weight: .medium)).foregroundStyle(Console.muted)
                Spacer()
                Button { name = ""; creatingWorkspace = true } label: {
                    Image(systemName: "plus").font(.system(size: 11))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Console.muted)
                .disabled(!session.canOrganizeChats)
                .accessibilityLabel("New workspace").help("New workspace")
            }.padding(.leading, 10).padding(.trailing, 4).padding(.bottom, 5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(session.workspaces) { workspace in
                        workspaceRow(workspace)
                    }
                    Divider().padding(.vertical, 12)
                    Button(action: openConsole) {
                        Label("Workspace console", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ChatSidebarRowStyle(selected: !isChatOpen))
                    .accessibilityValue(isChatOpen ? "" : "Selected")
                    HStack {
                        Text(session.selectedWorkspace.name).lineLimit(1)
                        Spacer()
                        Text("\(session.workspaceChats.count)")
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Console.muted)
                    .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 5)
                    ForEach(visibleChats) { chat in chatRow(chat) }
                    if visibleChats.isEmpty {
                        Text("No matching chats in this workspace")
                            .font(.system(size: 12)).foregroundStyle(Console.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }.padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            if !session.canOrganizeChats {
                Text("Chat switching is unavailable while a response or account check is running.")
                    .font(.system(size: 11)).foregroundStyle(Console.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(10)
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Console.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Console.line.opacity(0.5)))
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Chat name", text: $name)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let chat = renaming { session.renameChat(chat.id, to: name) }
                renaming = nil
            }
        }
        .alert("Delete chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let chat = deleting, activateWorkspace(chat.workspaceID) { session.deleteChat(chat.id) }
                deleting = nil
            }
        } message: { Text("This removes the saved conversation from this app. Completed tool actions remain.") }
        .alert("New workspace", isPresented: $creatingWorkspace) {
            TextField("Workspace name", text: $name)
            Button("Cancel", role: .cancel) { }
            Button("Create") { session.createWorkspace(named: name) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Rename workspace", isPresented: Binding(get: { editingWorkspace != nil }, set: { if !$0 { editingWorkspace = nil } })) {
            TextField("Workspace name", text: $name)
            Button("Cancel", role: .cancel) { editingWorkspace = nil }
            Button("Save") {
                if let workspace = editingWorkspace { session.renameWorkspace(workspace.id, to: name) }
                editingWorkspace = nil
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: session.selectedWorkspaceID) { _ in search = "" }
    }

    private func matches(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(query) }

    private var visibleChats: [SavedChat] {
        session.workspaceChats.filter { query.isEmpty || matches($0.title) }
    }

    private func activateWorkspace(_ id: UUID) -> Bool {
        guard session.canOrganizeChats else { return false }
        session.selectWorkspace(id)
        return session.selectedWorkspaceID == id
    }

    private func newChat(in workspace: ChatWorkspace) {
        guard activateWorkspace(workspace.id) else { return }
        session.newChat()
        openChat()
    }

    private func workspaceRow(_ workspace: ChatWorkspace) -> some View {
        let selected = workspace.id == session.selectedWorkspaceID
        return Button {
            guard activateWorkspace(workspace.id) else { return }
            openConsole()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                Text(workspace.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if selected { Circle().fill(Console.blue).frame(width: 5, height: 5) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ChatSidebarRowStyle(selected: selected))
        .disabled(!session.canOrganizeChats)
        .accessibilityLabel("Open \(workspace.name) workspace console")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Open Console") {
                if activateWorkspace(workspace.id) { openConsole() }
            }
            Button("New Chat") { newChat(in: workspace) }
            Button("Rename Workspace…") { name = workspace.name; editingWorkspace = workspace }
        }
    }

    private func chatRow(_ chat: SavedChat) -> some View {
        let selected = isChatOpen && chat.id == session.selectedChatID
        return Button {
            guard activateWorkspace(chat.workspaceID) else { return }
            session.selectChat(chat.id)
            openChat()
        } label: {
            HStack(spacing: 7) {
                if !chat.draft.isEmpty {
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Console.muted)
                }
                Text(chat.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ChatSidebarRowStyle(selected: selected))
        .disabled(!session.canOrganizeChats)
        .accessibilityLabel(chat.title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(chat.title + (chat.draft.isEmpty ? "" : " — Draft saved"))
        .contextMenu {
            Button("Rename…") { name = chat.title; renaming = chat }
            Button("Delete…", role: .destructive) { deleting = chat }
        }
    }
}

private struct ChatSidebarRowStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(selected ? Console.white : Console.text.opacity(0.85))
                .padding(.horizontal, 9).padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Console.text.opacity(selected ? 0.10 : hovering ? 0.05 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

struct ChatWorkspacePicker: View {
    @ObservedObject var session: ChatSession
    var openConsole: (() -> Void)? = nil
    @State private var editingName = false
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        Menu {
            ForEach(session.workspaces) { workspace in
                Button {
                    session.selectWorkspace(workspace.id)
                    if session.selectedWorkspaceID == workspace.id { openConsole?() }
                } label: {
                    if workspace.id == session.selectedWorkspaceID {
                        Label(workspace.name, systemImage: "checkmark")
                    } else { Text(workspace.name) }
                }
            }
            Divider()
            Button("New Workspace…") { name = ""; creating = true; editingName = true }
            Button("Rename Workspace…") { name = session.selectedWorkspace.name; creating = false; editingName = true }
        } label: {
            Label(session.selectedWorkspace.name, systemImage: "square.stack.3d.up")
                .font(Console.mono(10)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize().frame(maxWidth: 230, alignment: .leading)
        .foregroundStyle(Console.blue).disabled(!session.canOrganizeChats)
        .accessibilityLabel("Workspace").accessibilityValue(session.selectedWorkspace.name)
        .help("Open a workspace console")
        .alert(creating ? "New workspace" : "Rename workspace", isPresented: $editingName) {
            TextField("Workspace name", text: $name)
            Button("Cancel", role: .cancel) { }
            Button(creating ? "Create" : "Save") {
                if creating { session.createWorkspace(named: name) }
                else { session.renameWorkspace(session.selectedWorkspaceID, to: name) }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("Each workspace has its own console, notes, timer, activity, chats, and task folder.") }
    }
}
