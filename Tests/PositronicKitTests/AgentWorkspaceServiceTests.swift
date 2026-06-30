import Foundation
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("AgentWorkspaceService Tests")
struct AgentWorkspaceServiceTests {
    @Test("Create Workspace")
    func testCreateWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = AgentWorkspaceService(
            workspaceRoot: FileManager.default.temporaryDirectory,
            workspacePersistence: persistence
        )

        let uri = WorkspaceURI(host: "pk-runtime", path: "/test")
        let metadata: [String: AnyCodable] = ["key": .string("value")]

        let ws = try await repository.createWorkspace(
            uri: uri,
            location: .runtime,
            rootPath: "/tmp/ws",
            metadata: metadata
        )

        #expect(ws.uri == uri)
        #expect(ws.rootPath == "/tmp/ws")
        #expect(ws.metadata["key"]?.asString == "value")

        // Verify it was saved to persistence
        let saved = try await persistence.fetchWorkspace(id: ws.id)
        #expect(saved != nil)
        #expect(saved?.metadata["key"]?.asString == "value")
    }

    @Test("Get Workspace")
    func testGetWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = AgentWorkspaceService(
            workspaceRoot: FileManager.default.temporaryDirectory,
            workspacePersistence: persistence
        )

        let ws = WorkspaceReference(
            uri: .timelineWorkspace(UUID()),
            location: .runtime,
            rootPath: "/path",
            metadata: ["test": .boolean(true)]
        )
        try await persistence.saveWorkspace(ws)

        let retrieved = try await repository.getWorkspace(id: ws.id)
        #expect(retrieved != nil)
        #expect(retrieved?.id == ws.id)
        #expect(retrieved?.metadata["test"]?.value as? Bool == true)
    }

    @Test("List Workspaces")
    func testListWorkspaces() async throws {
        let persistence = MockPersistenceService()
        let repository = AgentWorkspaceService(
            workspaceRoot: FileManager.default.temporaryDirectory,
            workspacePersistence: persistence
        )

        let ws1 = WorkspaceReference(uri: .timelineWorkspace(UUID()), location: .runtime)
        let ws2 = WorkspaceReference(uri: .timelineWorkspace(UUID()), location: .runtime)
        try await persistence.saveWorkspace(ws1)
        try await persistence.saveWorkspace(ws2)

        let list = try await repository.listWorkspaces()
        #expect(list.count == 2)
        #expect(list.contains(where: { $0.id == ws1.id }))
        #expect(list.contains(where: { $0.id == ws2.id }))
    }

    @Test("Delete Workspace")
    func testDeleteWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = AgentWorkspaceService(
            workspaceRoot: FileManager.default.temporaryDirectory,
            workspacePersistence: persistence
        )

        let ws = WorkspaceReference(uri: .timelineWorkspace(UUID()), location: .runtime)
        try await persistence.saveWorkspace(ws)

        try await repository.deleteWorkspace(id: ws.id)
        let retrieved = try await persistence.fetchWorkspace(id: ws.id)
        #expect(retrieved == nil)
    }

    @Test("Update Workspace")
    func testUpdateWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = AgentWorkspaceService(
            workspaceRoot: FileManager.default.temporaryDirectory,
            workspacePersistence: persistence
        )

        var ws = WorkspaceReference(uri: .timelineWorkspace(UUID()), location: .runtime)
        try await persistence.saveWorkspace(ws)

        ws.status = .missing
        try await repository.updateWorkspace(ws)

        let retrieved = try await persistence.fetchWorkspace(id: ws.id)
        #expect(retrieved?.status == .missing)
    }

    @Test("Create Agent Workspace with Safe Seed Files")
    func createAgentWorkspaceWithSafeSeedFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = MockPersistenceService()
        let repository = AgentWorkspaceService(
            workspaceRoot: tempDir,
            workspacePersistence: persistence
        )

        let template = AgentTemplate(
            id: UUID(),
            name: "Test Template",
            description: "Test description",
            systemPrompt: "Test system prompt",
            workspaceFilesSeed: [
                "notes.md": "# Notes",
                "nested/file.md": "Nested content",
            ]
        )

        let instanceId = UUID()
        _ = try await repository.createAgentWorkspace(
            instanceId: instanceId,
            template: template,
            metadata: [:]
        )

        let notesPath = tempDir
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(instanceId.uuidString, isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)

        // Verify safe files were created
        let notesFile = notesPath.appendingPathComponent("notes.md")
        let nestedFile = notesPath.appendingPathComponent("nested/file.md")

        #expect(FileManager.default.fileExists(atPath: notesFile.path))
        #expect(FileManager.default.fileExists(atPath: nestedFile.path))

        let notesContent = try String(contentsOf: notesFile, encoding: .utf8)
        #expect(notesContent == "# Notes")

        let nestedContent = try String(contentsOf: nestedFile, encoding: .utf8)
        #expect(nestedContent == "Nested content")
    }

    @Test("Reject Agent Workspace Seed with Path Traversal ../")
    func rejectPathTraversalOutside() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = MockPersistenceService()
        let repository = AgentWorkspaceService(
            workspaceRoot: tempDir,
            workspacePersistence: persistence
        )

        let template = AgentTemplate(
            id: UUID(),
            name: "Test Template",
            description: "Test description",
            systemPrompt: "Test system prompt",
            workspaceFilesSeed: [
                "../outside.md": "Malicious content",
            ]
        )

        let instanceId = UUID()

        // Should throw because ../outside.md tries to escape Notes directory
        var didThrow = false
        do {
            _ = try await repository.createAgentWorkspace(
                instanceId: instanceId,
                template: template,
                metadata: [:]
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)

        // Verify no file was created outside Notes
        let outsideFile = tempDir.appendingPathComponent("outside.md")
        #expect(!FileManager.default.fileExists(atPath: outsideFile.path))
    }

    @Test("Reject Agent Workspace Seed with Absolute Path")
    func rejectAbsolutePath() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = MockPersistenceService()
        let repository = AgentWorkspaceService(
            workspaceRoot: tempDir,
            workspacePersistence: persistence
        )

        let evilPath = "/tmp/evil.md"
        let template = AgentTemplate(
            id: UUID(),
            name: "Test Template",
            description: "Test description",
            systemPrompt: "Test system prompt",
            workspaceFilesSeed: [
                evilPath: "Malicious content",
            ]
        )

        let instanceId = UUID()

        // Should throw because absolute path is not allowed
        var didThrow = false
        do {
            _ = try await repository.createAgentWorkspace(
                instanceId: instanceId,
                template: template,
                metadata: [:]
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }

    @Test("Reject Agent Workspace Seed with Multiple Traversal Segments")
    func rejectMultipleTraversalSegments() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = MockPersistenceService()
        let repository = AgentWorkspaceService(
            workspaceRoot: tempDir,
            workspacePersistence: persistence
        )

        let template = AgentTemplate(
            id: UUID(),
            name: "Test Template",
            description: "Test description",
            systemPrompt: "Test system prompt",
            workspaceFilesSeed: [
                "../../evil.md": "Malicious content",
            ]
        )

        let instanceId = UUID()

        // Should throw because ../../evil.md tries to escape
        var didThrow = false
        do {
            _ = try await repository.createAgentWorkspace(
                instanceId: instanceId,
                template: template,
                metadata: [:]
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)

        // Verify no files were created outside the workspace
        let evilFile = tempDir.appendingPathComponent("evil.md")
        #expect(!FileManager.default.fileExists(atPath: evilFile.path))
    }
}
