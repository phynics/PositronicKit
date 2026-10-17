import Foundation
import PKAgentFiles
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("PKAgentFiles filesystem Agent context", .tags(.integration))
struct FileSystemAgentContextSourceTests {
    @Test("loads SOUL and refreshes a discoverable Notes catalog")
    func defaultContextCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Agent identity\nBe concise.".write(to: root.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try "---\ndescription: Durable preferences\n---\n# Preferences\n".write(
            to: root.appendingPathComponent("Notes/preferences.md"), atomically: true, encoding: .utf8
        )

        let agentID = UUID()
        let workspaceID = UUID()
        let store = InMemoryWorkspacePersistence()
        try await store.saveWorkspace(WorkspaceReference(
            id: workspaceID,
            uri: .agentWorkspace(agentID),
            location: .runtime,
            rootPath: root.path
        ))
        let source = FileSystemAgentContextSource(workspaceStore: store)
        let agent = Agent(id: agentID, name: "Catalog", description: "test", primaryWorkspaceID: workspaceID, privateTimelineID: UUID())
        let timeline = TimelineRecord()

        let first = try await source.snapshot(for: agent, timeline: timeline)
        #expect(first.instructions.contains("Agent identity"))
        #expect(first.memories.isEmpty)
        #expect(first.resources == [AgentContextResource(path: "Notes/preferences.md", description: "Durable preferences")])
        #expect(!first.diagnostics.contains(where: { $0.operation == "readSoul" }))

        try "# New note".write(to: root.appendingPathComponent("Notes/new.md"), atomically: true, encoding: .utf8)
        let refreshed = try await source.snapshot(for: agent, timeline: timeline)
        #expect(refreshed.resources.count == 2)
    }

    @Test("an Agent without a filesystem workspace gets identity-only context")
    func identityOnlyWithoutWorkspace() async throws {
        let source = FileSystemAgentContextSource(workspaceStore: InMemoryWorkspacePersistence())
        let agent = Agent(name: "No workspace", description: "identity", privateTimelineID: UUID())

        let snapshot = try await source.snapshot(for: agent, timeline: TimelineRecord())

        #expect(snapshot.identity.agentID == agent.id)
        #expect(snapshot.instructions.isEmpty)
        #expect(snapshot.resources.isEmpty)
    }
}
