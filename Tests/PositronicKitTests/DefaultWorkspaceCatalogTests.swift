import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("DefaultWorkspaceCatalog Tests")
struct AgentWorkspaceServiceTests {
    @Test("Create Workspace")
    func testCreateWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: FileManager.default.temporaryDirectory,
            workspacePersistence: persistence
        )

        let uri = WorkspaceURI(host: "pk-runtime", path: "/test")

        let ws = try await repository.createWorkspace(
            uri: uri,
            location: .runtime,
            rootPath: "/tmp/ws"
        )

        #expect(ws.uri == uri)
        #expect(ws.rootPath == "/tmp/ws")

        // Verify it was saved to persistence
        let saved = try await persistence.fetchWorkspace(id: ws.id)
        #expect(saved != nil)
    }

    @Test("Get Workspace")
    func testGetWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: FileManager.default.temporaryDirectory,
            workspacePersistence: persistence
        )

        let ws = WorkspaceReference(
            uri: .timelineWorkspace(UUID()),
            location: .runtime,
            rootPath: "/path"
        )
        try await persistence.saveWorkspace(ws)

        let retrieved = try await repository.getWorkspace(id: ws.id)
        #expect(retrieved != nil)
        #expect(retrieved?.id == ws.id)
    }

    @Test("List Workspaces")
    func testListWorkspaces() async throws {
        let persistence = MockPersistenceService()
        let repository = DefaultWorkspaceCatalog(
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
        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: FileManager.default.temporaryDirectory,
            workspacePersistence: persistence
        )

        let ws = WorkspaceReference(uri: .timelineWorkspace(UUID()), location: .runtime)
        try await persistence.saveWorkspace(ws)

        try await repository.deleteWorkspace(id: ws.id)
        let retrieved = try await persistence.fetchWorkspace(id: ws.id)
        #expect(retrieved == nil)
    }

    @Test("Reject Workspace Root Path Outside Workspace Root")
    func deleteWorkspaceRejectsRootPathOutsideWorkspaceRoot() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceRoot = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "must remain".write(to: sentinel, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = MockPersistenceService()
        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: workspaceRoot,
            workspacePersistence: persistence
        )
        let ws = WorkspaceReference(
            uri: .timelineWorkspace(UUID()),
            location: .runtime,
            rootPath: outside.path
        )
        try await persistence.saveWorkspace(ws)

        do {
            try await repository.deleteWorkspace(id: ws.id, deleteDirectory: true)
            Issue.record("Expected workspace directory deletion to be rejected")
        } catch let error as WorkspaceError {
            guard case .accessDenied = error else {
                Issue.record("Expected WorkspaceError.accessDenied, got \(error)")
                return
            }
        }

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        let persistedWorkspace = try await persistence.fetchWorkspace(id: ws.id)
        #expect(persistedWorkspace != nil)
    }

    @Test("Reject Workspace Root Path Traversal")
    func deleteWorkspaceRejectsTraversalPath() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceRoot = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "must remain".write(to: sentinel, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = MockPersistenceService()
        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: workspaceRoot,
            workspacePersistence: persistence
        )
        let ws = WorkspaceReference(
            uri: .timelineWorkspace(UUID()),
            location: .runtime,
            rootPath: workspaceRoot.appendingPathComponent("../outside").path
        )
        try await persistence.saveWorkspace(ws)

        do {
            try await repository.deleteWorkspace(id: ws.id, deleteDirectory: true)
            Issue.record("Expected workspace directory deletion to be rejected")
        } catch is WorkspaceError {
            // Expected.
        }

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        let persistedWorkspace = try await persistence.fetchWorkspace(id: ws.id)
        #expect(persistedWorkspace != nil)
    }

    @Test("Reject Workspace Root Path Symlink Escape")
    func deleteWorkspaceRejectsSymlinkEscape() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceRoot = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        let escapedPath = workspaceRoot.appendingPathComponent("escaped", isDirectory: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escapedPath, withDestinationURL: outside)
        try "must remain".write(to: sentinel, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = MockPersistenceService()
        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: workspaceRoot,
            workspacePersistence: persistence
        )
        let ws = WorkspaceReference(
            uri: .timelineWorkspace(UUID()),
            location: .runtime,
            rootPath: escapedPath.path
        )
        try await persistence.saveWorkspace(ws)

        do {
            try await repository.deleteWorkspace(id: ws.id, deleteDirectory: true)
            Issue.record("Expected workspace directory deletion to be rejected")
        } catch is WorkspaceError {
            // Expected.
        }

        #expect(FileManager.default.fileExists(atPath: escapedPath.path))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        let persistedWorkspace = try await persistence.fetchWorkspace(id: ws.id)
        #expect(persistedWorkspace != nil)
    }

    @Test("Update Workspace")
    func testUpdateWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = DefaultWorkspaceCatalog(
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
        let repository = DefaultWorkspaceCatalog(
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
            template: template
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

    @Test("Create Agent Workspace Cleans Up Directory After Provisioning Failure")
    func createAgentWorkspaceCleansUpDirectoryAfterProvisioningFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let seedFailureInstanceID = UUID()
        let seedFailureRepository = DefaultWorkspaceCatalog(workspaceRoot: tempDir)
        let invalidTemplate = AgentTemplate(
            id: UUID(),
            name: "Invalid Template",
            description: "Seed failure",
            systemPrompt: "Instructions",
            workspaceFilesSeed: ["../outside.md": "must fail"]
        )

        do {
            _ = try await seedFailureRepository.createAgentWorkspace(
                instanceId: seedFailureInstanceID,
                template: invalidTemplate
            )
            Issue.record("Expected seed provisioning to fail")
        } catch let error as PathSanitizer.PathError {
            guard case .accessDenied = error else {
                Issue.record("Expected PathSanitizer.PathError.accessDenied, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected seed provisioning error: \(error)")
        }

        let seedFailureWorkspaceURL = tempDir
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(seedFailureInstanceID.uuidString, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: seedFailureWorkspaceURL.path))

        let persistenceFailureInstanceID = UUID()
        let persistenceFailureRepository = DefaultWorkspaceCatalog(
            workspaceRoot: tempDir,
            workspacePersistence: FailingWorkspaceStore(saveFails: true)
        )
        let validTemplate = AgentTemplate(
            id: UUID(),
            name: "Valid Template",
            description: "Persistence failure",
            systemPrompt: "Instructions",
            workspaceFilesSeed: ["system.md": "content"]
        )

        do {
            _ = try await persistenceFailureRepository.createAgentWorkspace(
                instanceId: persistenceFailureInstanceID,
                template: validTemplate
            )
            Issue.record("Expected persistence to fail")
        } catch let error as FailingStoreError {
            guard case .saveFailed = error else {
                Issue.record("Expected FailingStoreError.saveFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected persistence error: \(error)")
        }

        let persistenceFailureWorkspaceURL = tempDir
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(persistenceFailureInstanceID.uuidString, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: persistenceFailureWorkspaceURL.path))

        let existingInstanceID = UUID()
        let existingWorkspaceURL = tempDir
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(existingInstanceID.uuidString, isDirectory: true)
        let sentinel = existingWorkspaceURL.appendingPathComponent("sentinel.txt")
        try FileManager.default.createDirectory(at: existingWorkspaceURL, withIntermediateDirectories: true)
        try "keep".write(to: sentinel, atomically: true, encoding: .utf8)

        do {
            _ = try await persistenceFailureRepository.createAgentWorkspace(
                instanceId: existingInstanceID,
                template: validTemplate
            )
            Issue.record("Expected persistence to fail for the existing workspace")
        } catch is FailingStoreError {
            // Expected.
        }

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("Reject Agent Workspace Seed with Path Traversal ../")
    func rejectPathTraversalOutside() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = MockPersistenceService()
        let repository = DefaultWorkspaceCatalog(
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
                template: template
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
        let repository = DefaultWorkspaceCatalog(
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
                template: template
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
        let repository = DefaultWorkspaceCatalog(
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
                template: template
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
