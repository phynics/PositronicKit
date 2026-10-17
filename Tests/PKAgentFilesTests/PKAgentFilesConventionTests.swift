import Foundation
import PKAgentFiles
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("PKAgentFiles conventions", .tags(.integration))
struct PKAgentFilesConventionTests {
    @Test("the adapter names the identity file as a protected write path")
    func protectedPaths() {
        #expect(PKAgentFiles.protectedPaths == ["SOUL.md"])
    }

    @Test("installed protected paths gate identity-file mutations")
    func protectedWriteApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reference = WorkspaceReference(uri: .agentWorkspace(UUID()), location: .runtime, rootPath: root.path)
        let provider = try LocalAgentWorkspaceProvider(reference: reference)
        let write = AgentWorkspaceFileTool(
            operation: .writeFile,
            provider: provider,
            protectedPaths: PKAgentFiles.protectedPaths
        )

        try "identity".write(to: root.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Notes/soul-alias.md").path,
            withDestinationPath: root.appendingPathComponent("SOUL.md").path
        )
        #expect(write.requiresPermission(for: ["path": "SOUL.md", "content": "new identity"]))
        #expect(write.requiresPermission(for: ["path": "soul.md", "content": "new identity"]))
        #expect(write.requiresPermission(for: ["path": "Notes/soul-alias.md", "content": "new identity"]))
        #expect(!write.requiresPermission(for: ["path": "Notes/MEMORY.md", "content": "new memory"]))
    }

    @Test("the seed writes the identity file and Notes memory template")
    func seedWritesConventions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: root,
            workspacePersistence: InMemoryWorkspacePersistence(),
            agentWorkspaceSeed: PKAgentFiles.seedNotes
        )
        let template = AgentTemplate(
            id: UUID(),
            name: "Seeded",
            description: "seed",
            systemPrompt: "You are the seeded Agent."
        )
        let agentID = UUID()
        _ = try await repository.createAgentWorkspace(agentID: agentID, template: template)

        let workspaceURL = root
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agentID.uuidString, isDirectory: true)
        let soul = try String(contentsOf: workspaceURL.appendingPathComponent("SOUL.md"), encoding: .utf8)
        let memory = try String(contentsOf: workspaceURL.appendingPathComponent("Notes/MEMORY.md"), encoding: .utf8)
        #expect(soul.contains("You are the seeded Agent."))
        #expect(memory.contains("# Memory"))
    }

    @Test("the customization helper installs the context source and seed")
    func customizationHelper() {
        let customization = RuntimeCustomization.agentFiles(workspaceStore: InMemoryWorkspacePersistence())

        #expect(customization.agentContextSource is FileSystemAgentContextSource)
        #expect(customization.agentWorkspaceSeed != nil)
    }

    @Test("the runtime configuration helper installs all three conventions")
    func runtimeConfigurationHelper() {
        let persistence = PKRuntime.PersistenceConfiguration(runtimeRepository: InMemoryTimelineRuntimeRepository())
        let runtime = PKRuntime.RuntimeConfiguration.agentFiles(
            persistence: persistence,
            workspaceProfile: .noWorkspace
        )

        #expect(runtime.runtimeToolPolicy.protectedPrimaryWorkspacePaths == PKAgentFiles.protectedPaths)
        #expect(runtime.customization.agentContextSource is FileSystemAgentContextSource)
        #expect(runtime.customization.agentWorkspaceSeed != nil)
    }
}
