import Foundation
import Testing
@testable import VaydeAOSCore

@Suite("Workspace telemetry")
struct WorkspaceTelemetryTests {
    @Test func packetParserRequiresDeliveryEvidence() throws {
        #expect(WorkspacePacket.parse("I (123) node: Heartbeat queued") == nil)
        #expect(WorkspacePacket.parse("I (123) node: Heartbeat sent") == nil)
        #expect(WorkspacePacket.parse("not a packet {\"sequence\":7}") == nil)
        let line = "I (123) sink: Logical message delivered: version=1 type=1 length=4 source=42 sequence=17 payload=\"ping\""
        let packet = try #require(WorkspacePacket.parse(line))
        #expect(packet.sender == "42")
        #expect(packet.sequence == "17")
        #expect(packet.info == "ping")
        #expect(packet.result == "RECEIVED")
        #expect(!packet.outbound)
        #expect(packet.deliveryConfirmed)
        #expect(packet.transport == "VaydeNet")
    }

    @Test func jsonRecordsPreserveReportedResultsAndDirection() throws {
        let packet = try #require(WorkspacePacket.parse("{\"transport\":\"ESP-NOW\",\"senderID\":12,\"sequenceNumber\":9,\"direction\":\"tx\",\"result\":\"TIMEOUT\"}"))
        #expect(packet.outbound)
        #expect(packet.result == "TIMEOUT")
        #expect(packet.sequence == "9")
        #expect(!packet.deliveryConfirmed)
        let unknown = try #require(WorkspacePacket.parse("{\"transport\":\"nRF24\",\"sender\":\"node\",\"sequence\":1}"))
        #expect(unknown.result == "REPORTED")
        #expect(unknown.direction == "—")
        #expect(!unknown.deliveryConfirmed)
    }

    @Test func nonRepositoryDoesNotInventGitOrFirmwareState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = WorkspaceProjectSnapshot.read(directory: directory.path)
        #expect(!snapshot.isRepository)
        #expect(snapshot.commit.isEmpty)
        #expect(snapshot.suggestedCommand.isEmpty)
        #expect(snapshot.target == "Choose a build command")
    }

    @MainActor @Test func projectSelectionPersistsAndSharesAgentDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(directory: directory.appendingPathComponent("store"))
        let session = ChatSession(store: store)
        let firstID = session.selectedWorkspaceID
        try session.selectWorkspaceProject(project.path)
        session.updateWorkspaceConsole {
            $0.buildCommand = "swift build"; $0.scratchpad = "test note"
            $0.studentDB.sourcePath = "src/recordgen.cpp"
            $0.studentDB.selectedTab = "CLI SESSION"
        }
        #expect(session.workspaceDirectory == project.resolvingSymlinksInPath())
        #expect(session.settings.codexWorkspace == project.resolvingSymlinksInPath().path)
        session.createWorkspace(named: "Other")
        #expect(session.workspaceConsole.projectDirectory == nil)
        #expect(session.workspaceConsole.buildCommand == nil)
        #expect(session.workspaceConsole.studentDB.sourcePath == "src/main.cpp")
        #expect(session.workspaceConsole.studentDB.selectedTab == "SOURCE TRACE")
        session.selectWorkspace(firstID)
        let restored = ChatSession(store: store)
        #expect(restored.workspaceDirectory == project.resolvingSymlinksInPath())
        #expect(restored.settings.codexWorkspace == project.resolvingSymlinksInPath().path)
        #expect(restored.workspaceConsole.buildCommand == "swift build")
        #expect(restored.workspaceConsole.scratchpad == "test note")
        #expect(restored.workspaceConsole.studentDB.sourcePath == "src/recordgen.cpp")
        #expect(restored.workspaceConsole.studentDB.selectedTab == "CLI SESSION")
    }

    @Test func studentDBProfileAndLegacyWorkspaceState() throws {
        #expect(StudentDBWorkspace.matches(name: "StudentDB", directory: "/tmp/workspace"))
        #expect(StudentDBWorkspace.matches(name: "C++", directory: "/tmp/StudentDB(deploy)"))
        #expect(!StudentDBWorkspace.matches(name: "VaydeNet", directory: "/tmp/VaydeNet"))
        let encoded = try JSONEncoder().encode(WorkspaceConsoleState())
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "studentDB")
        let restored = try JSONDecoder().decode(WorkspaceConsoleState.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.studentDB == StudentDBConsoleState())
    }

    @Test func studentDBSourceReaderStaysInsideProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "int main() {}".write(to: root.appendingPathComponent("src/main.cpp"), atomically: true, encoding: .utf8)
        #expect(StudentDBWorkspace.readSource("src/main.cpp", directory: root.path) == "int main() {}")
        #expect(StudentDBWorkspace.readSource("include/login/tempcreds.h", directory: root.path) == nil)
        #expect(StudentDBWorkspace.readSource("../outside", directory: root.path) == nil)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/student.cpp"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("outside"))
        #expect(StudentDBWorkspace.readSource("src/student.cpp", directory: root.path) == nil)
    }
}
