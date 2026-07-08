import Foundation
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

// MARK: - Test doubles

private struct TestError: Error, Equatable {
    static let repositoryFailure = TestError()
}

/// Lightweight in-memory repository for `WorkspaceManager` unit tests.
private actor FakeWorkspaceRepository: AgentWorkspaceServiceProtocol {
    private var references: [UUID: WorkspaceReference] = [:]
    private var shouldThrow = false

    func addReference(_ reference: WorkspaceReference) {
        references[reference.id] = reference
    }

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func getWorkspace(id: UUID, includeTools: Bool) async throws -> WorkspaceReference? {
        if shouldThrow {
            throw TestError.repositoryFailure
        }
        return references[id]
    }

    func createWorkspace(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originId: UUID?,
        rootPath: String?,
        metadata: [String: AnyCodable]
    ) async throws -> WorkspaceReference {
        let reference = WorkspaceReference(
            id: UUID(),
            uri: uri,
            location: location,
            originId: originId,
            rootPath: rootPath,
            metadata: metadata
        )
        references[reference.id] = reference
        return reference
    }

    func createAgentWorkspace(
        instanceId: UUID,
        template: AgentTemplate?,
        metadata: [String: AnyCodable]
    ) async throws -> WorkspaceReference {
        let reference = WorkspaceReference(
            uri: .agentWorkspace(instanceId),
            location: .runtime,
            metadata: metadata
        )
        references[reference.id] = reference
        return reference
    }

    func listWorkspaces() async throws -> [WorkspaceReference] {
        Array(references.values)
    }

    func deleteWorkspace(id: UUID, deleteDirectory: Bool) async throws {
        references.removeValue(forKey: id)
    }

    func updateWorkspace(_ workspace: WorkspaceReference) async throws {
        references[workspace.id] = workspace
    }
}

/// Minimal workspace whose health check can be controlled from the test.
private actor FakeWorkspace: WorkspaceProtocol {
    let reference: WorkspaceReference
    nonisolated let id: UUID
    private let healthy: Bool

    init(reference: WorkspaceReference, healthy: Bool = true) {
        self.reference = reference
        self.id = reference.id
        self.healthy = healthy
    }

    func listTools() async throws -> [ToolReference] { [] }

    func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        throw WorkspaceError.toolExecutionNotSupported
    }

    func readFile(path: String) async throws -> String { "" }
    func writeFile(path: String, content: String) async throws {}
    func listFiles(path: String) async throws -> [String] { [] }
    func deleteFile(path: String) async throws {}

    func healthCheck() async -> Bool { healthy }
}

/// Creator that vends `FakeWorkspace` instances with per-ID health overrides.
private struct FakeWorkspaceCreator: WorkspaceCreating {
    var healthByID: [UUID: Bool] = [:]

    func create(from reference: WorkspaceReference) throws -> any WorkspaceProtocol {
        FakeWorkspace(reference: reference, healthy: healthByID[reference.id] ?? true)
    }
}

// MARK: - Helpers

private func makeReference(id: UUID = UUID()) -> WorkspaceReference {
    WorkspaceReference(
        id: id,
        uri: .timelineWorkspace(id),
        location: .runtime,
        rootPath: "/tmp/\(id.uuidString)"
    )
}

private func makeManager(
    references: [WorkspaceReference] = [],
    healthByID: [UUID: Bool] = [:]
) async -> (manager: WorkspaceManager, repository: FakeWorkspaceRepository, creator: FakeWorkspaceCreator) {
    let repository = FakeWorkspaceRepository()
    for reference in references {
        await repository.addReference(reference)
    }
    let creator = FakeWorkspaceCreator(healthByID: healthByID)
    let manager = WorkspaceManager(repository: repository, workspaceCreator: creator)
    return (manager, repository, creator)
}

// MARK: - Tests

@Suite("WorkspaceManager Tests")
struct WorkspaceManagerTests {
    @Test("activeWorkspaceCount starts at zero")
    func startsEmpty() async throws {
        let (manager, _, _) = await makeManager()
        #expect(await manager.activeWorkspaceCount == 0)
    }

    @Test("getWorkspace creates and caches a workspace")
    func getWorkspaceCreatesAndCaches() async throws {
        let id = UUID()
        let reference = makeReference(id: id)
        let (manager, _, _) = await makeManager(references: [reference])

        let first = try #require(await manager.getWorkspace(id: id) as? FakeWorkspace)
        #expect(await manager.activeWorkspaceCount == 1)

        let second = try #require(await manager.getWorkspace(id: id) as? FakeWorkspace)
        #expect(first === second)
    }

    @Test("getWorkspace returns the same cached instance")
    func getWorkspaceReturnsSameInstance() async throws {
        let id = UUID()
        let reference = makeReference(id: id)
        let (manager, _, _) = await makeManager(references: [reference])

        let first = try #require(await manager.getWorkspace(id: id) as? FakeWorkspace)
        let second = try #require(await manager.getWorkspace(id: id) as? FakeWorkspace)
        let third = try #require(await manager.getWorkspace(id: id) as? FakeWorkspace)

        #expect(first === second)
        #expect(second === third)
        #expect(await manager.activeWorkspaceCount == 1)
    }

    @Test("closeWorkspace evicts the cached workspace")
    func closeWorkspaceEvictsCache() async throws {
        let id = UUID()
        let reference = makeReference(id: id)
        let (manager, _, _) = await makeManager(references: [reference])

        let first = try #require(await manager.getWorkspace(id: id) as? FakeWorkspace)
        await manager.closeWorkspace(id: id)

        #expect(await manager.activeWorkspaceCount == 0)

        let second = try #require(await manager.getWorkspace(id: id) as? FakeWorkspace)
        #expect(first !== second)
        #expect(await manager.activeWorkspaceCount == 1)
    }

    @Test("closeWorkspace for an unknown ID is harmless")
    func closeUnknownWorkspaceIsHarmless() async throws {
        let id = UUID()
        let (manager, _, _) = await makeManager()
        await manager.closeWorkspace(id: id)
        #expect(await manager.activeWorkspaceCount == 0)
    }

    @Test("getWorkspace returns nil for an unknown ID")
    func getWorkspaceUnknownReturnsNil() async throws {
        let id = UUID()
        let (manager, _, _) = await makeManager()
        let workspace = try await manager.getWorkspace(id: id)
        #expect(workspace == nil)
        #expect(await manager.activeWorkspaceCount == 0)
    }

    @Test("getWorkspace propagates repository errors")
    func getWorkspacePropagatesErrors() async throws {
        let id = UUID()
        let reference = makeReference(id: id)
        let (manager, repository, _) = await makeManager(references: [reference])
        await repository.setShouldThrow(true)

        await #expect(throws: TestError.repositoryFailure) {
            _ = try await manager.getWorkspace(id: id)
        }
    }

    @Test("healthCheckAll reports true and preserves cache when all workspaces are healthy")
    func healthCheckAllHealthyPreservesCache() async throws {
        let id1 = UUID()
        let id2 = UUID()
        let references = [makeReference(id: id1), makeReference(id: id2)]
        let (manager, _, _) = await makeManager(references: references)

        _ = try await manager.getWorkspace(id: id1)
        _ = try await manager.getWorkspace(id: id2)
        #expect(await manager.activeWorkspaceCount == 2)

        let results = await manager.healthCheckAll()

        #expect(results[id1] == true)
        #expect(results[id2] == true)
        #expect(await manager.activeWorkspaceCount == 2)
    }

    @Test("healthCheckAll reports false and evicts an unhealthy workspace")
    func healthCheckAllEvictsUnhealthy() async throws {
        let healthyID = UUID()
        let unhealthyID = UUID()
        let references = [makeReference(id: healthyID), makeReference(id: unhealthyID)]
        let (manager, _, _) = await makeManager(
            references: references,
            healthByID: [unhealthyID: false]
        )

        _ = try await manager.getWorkspace(id: healthyID)
        _ = try await manager.getWorkspace(id: unhealthyID)
        #expect(await manager.activeWorkspaceCount == 2)

        let results = await manager.healthCheckAll()

        #expect(results[healthyID] == true)
        #expect(results[unhealthyID] == false)
        #expect(await manager.activeWorkspaceCount == 1)

        let remaining = try await manager.getWorkspace(id: healthyID)
        #expect(remaining != nil)
        let evicted = try await manager.getWorkspace(id: unhealthyID)
        #expect(evicted != nil)
        #expect(await manager.activeWorkspaceCount == 2)
    }

    @Test("healthCheckAll aggregates mixed results and evicts only unhealthy workspaces")
    func healthCheckAllAggregatesMixedResults() async throws {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let references = [makeReference(id: id1), makeReference(id: id2), makeReference(id: id3)]
        let (manager, _, _) = await makeManager(
            references: references,
            healthByID: [id1: false, id3: false]
        )

        _ = try await manager.getWorkspace(id: id1)
        _ = try await manager.getWorkspace(id: id2)
        _ = try await manager.getWorkspace(id: id3)
        #expect(await manager.activeWorkspaceCount == 3)

        let results = await manager.healthCheckAll()

        #expect(results[id1] == false)
        #expect(results[id2] == true)
        #expect(results[id3] == false)
        #expect(await manager.activeWorkspaceCount == 1)

        let remaining = try await manager.getWorkspace(id: id2)
        #expect(remaining != nil)
    }

    @Test("concurrent open, get, and close interleaving keeps invariants")
    func concurrentInterleaving() async throws {
        let ids = (0..<5).map { _ in UUID() }
        let references = ids.map { makeReference(id: $0) }
        let (manager, _, _) = await makeManager(references: references)

        for id in ids {
            _ = try await manager.getWorkspace(id: id)
        }
        #expect(await manager.activeWorkspaceCount == ids.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    let id = ids[i % ids.count]
                    switch i % 3 {
                    case 0:
                        _ = try await manager.getWorkspace(id: id)
                    case 1:
                        await manager.closeWorkspace(id: id)
                    case 2:
                        _ = try await manager.getWorkspace(id: id)
                    default:
                        break
                    }
                }
            }
            try await group.waitForAll()
        }

        let finalCount = await manager.activeWorkspaceCount
        #expect(finalCount >= 0)
        #expect(finalCount <= ids.count)
    }
}
