import Foundation
@testable import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

/// Contract coverage for PKV3-002: a host can hand `TimelineManager` a fully custom
/// `WorkspaceResolver` — one that involves no `DefaultWorkspaceCatalog`/`DefaultWorkspaceResolver`
/// internals at all — and the timeline lifecycle (create, hydrate, attach) still works end to end.
@Suite("TimelineManager + custom WorkspaceResolver contract", .tags(.unit))
struct TimelineManagerWorkspaceResolverContractTests {
    /// A resolver that vends a single fixed, always-healthy in-memory workspace for any ID and
    /// keeps no catalog/factory collaborators of its own.
    private final actor FixedWorkspaceResolver: WorkspaceResolver {
        private var opened: Set<UUID> = []

        var activeWorkspaceCount: Int { opened.count }

        func workspace(id: UUID) async throws -> any WorkspaceProvider? {
            opened.insert(id)
            return CustomFixedWorkspace(id: id)
        }

        func closeWorkspace(id: UUID) async {
            opened.remove(id)
        }

        func healthCheckAll() async -> [UUID: Bool] {
            Dictionary(uniqueKeysWithValues: opened.map { ($0, true) })
        }
    }

    private actor CustomFixedWorkspace: WorkspaceFileProvider {
        nonisolated private let workspaceID: UUID
        nonisolated var reference: WorkspaceReference {
            WorkspaceReference(id: workspaceID, uri: .timelineWorkspace(workspaceID), location: .runtime)
        }

        init(id: UUID) {
            self.workspaceID = id
        }

        func readFile(path: String) async throws -> String { "" }
        func writeFile(path: String, content: String) async throws {}
        func listFiles(path: String) async throws -> [String] { [] }
        func deleteFile(path: String) async throws {}
        var isHealthy: Bool { get async { true } }
    }

    @Test("TimelineManager built with a custom WorkspaceResolver creates and hydrates timelines")
    func createAndHydrateWithCustomResolver() async throws {
        let workspace = TestWorkspace()
        let workspaceStore = InMemoryWorkspacePersistence()

        let manager = TimelineManager(
            stores: .init(
                timelineStore: InMemoryTimelinePersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: workspaceStore,
                workspaceBindingRepository: workspaceStore,
                runtimeRepository: InMemoryTimelineRuntimeRepository()
            ),
            workspaceProfile: .hostManaged(root: workspace.root),
            resolver: FixedWorkspaceResolver()
        )

        let timeline = try await manager.createTimeline(title: "Custom Resolver Timeline")
        #expect(timeline.title == "Custom Resolver Timeline")
        #expect(await manager.timeline(id: timeline.id) != nil)

        await manager.evictTimelineFromMemory(id: timeline.id)
        #expect(await manager.timeline(id: timeline.id) == nil)

        try await manager.hydrateTimeline(id: timeline.id)
        #expect(await manager.timeline(id: timeline.id) != nil)
    }
}
