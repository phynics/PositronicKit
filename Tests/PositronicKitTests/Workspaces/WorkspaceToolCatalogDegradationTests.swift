import Foundation
@testable import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

/// Regression coverage for catalog capture no longer swallowing resolver and `listTools`
/// failures. The attach path already records a `.workspace` degradation for the same class of
/// failure; admission catalog capture must do the same so the failure is observable through the
/// Turn degradation lane instead of silently yielding an empty tool set.
@Suite("Workspace tool catalog capture degradations", .tags(.unit))
struct WorkspaceToolCatalogDegradationTests {
    private struct FixedResolver: WorkspaceResolver {
        let provider: any WorkspaceProvider

        func workspace(id _: UUID) async throws -> any WorkspaceProvider? { provider }
    }

    private struct ThrowingResolver: WorkspaceResolver {
        func workspace(id _: UUID) async throws -> any WorkspaceProvider? {
            throw FailingStoreError.fetchFailed
        }
    }

    private struct ThrowingToolProvider: WorkspaceToolProvider {
        let reference: WorkspaceReference

        var isHealthy: Bool { get async { true } }

        func listTools() async throws -> [ToolReference] {
            throw FailingStoreError.fetchFailed
        }

        func executeTool(id _: String, parameters _: [String: AnyCodable]) async throws -> ToolResult {
            throw WorkspaceError.toolExecutionNotSupported
        }
    }

    private func makeManager(
        persistence: MockPersistenceService,
        resolver: any WorkspaceResolver
    ) -> TimelineManager {
        TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence
            ),
            workspaceProfile: .noWorkspace,
            resolver: resolver
        )
    }

    @Test("listTools failure during catalog capture records a degradation")
    func listToolsFailureRecordsDegradation() async throws {
        let persistence = MockPersistenceService()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "degrade", path: "/tools"),
            location: .runtime,
            rootPath: "/tmp"
        )
        let manager = makeManager(
            persistence: persistence,
            resolver: FixedResolver(provider: ThrowingToolProvider(reference: workspace))
        )
        let timeline = try await manager.createTimeline(title: "catalog degradation")
        try await persistence.saveWorkspace(workspace)
        try await manager.attachWorkspace(workspace.id, to: timeline.id)

        _ = try await manager.captureWorkspaceToolCatalog(for: timeline.id, primaryWorkspaceID: nil)

        let degradations = await manager.consumeDegradations(for: timeline.id)
        #expect(degradations.contains {
            $0.operation == "captureWorkspaceCatalog.listTools"
                && $0.entityID == "workspace:\(workspace.id.uuidString.prefix(8))"
        }, "A listTools failure must be recorded, not silently collapsed to an empty tool set")
    }

    @Test("resolver failure during catalog capture records a degradation")
    func resolverFailureRecordsDegradation() async throws {
        let persistence = MockPersistenceService()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "degrade", path: "/resolve"),
            location: .runtime,
            rootPath: "/tmp"
        )
        let manager = makeManager(persistence: persistence, resolver: ThrowingResolver())
        let timeline = try await manager.createTimeline(title: "catalog degradation")
        try await persistence.saveWorkspace(workspace)
        try await manager.attachWorkspace(workspace.id, to: timeline.id)

        _ = try await manager.captureWorkspaceToolCatalog(for: timeline.id, primaryWorkspaceID: nil)

        let degradations = await manager.consumeDegradations(for: timeline.id)
        #expect(degradations.contains {
            $0.operation == "captureWorkspaceCatalog.resolveWorkspace"
                && $0.entityID == "workspace:\(workspace.id.uuidString.prefix(8))"
        }, "A resolver failure must be recorded, not silently collapsed to an empty tool set")
    }
}
