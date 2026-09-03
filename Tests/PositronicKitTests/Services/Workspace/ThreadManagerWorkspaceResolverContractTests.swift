import Foundation
@testable import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

/// Contract coverage for PKV3-002: a host can hand `ThreadManager` a fully custom
/// `WorkspaceResolver` — one that involves no `DefaultWorkspaceCatalog`/`DefaultWorkspaceResolver`
/// internals at all — and the thread lifecycle (create, hydrate, attach) still works end to end.
@Suite("ThreadManager + custom WorkspaceResolver contract")
struct ThreadManagerWorkspaceResolverContractTests {
    /// A resolver that vends a single fixed, always-healthy in-memory workspace for any ID and
    /// keeps no catalog/factory collaborators of its own.
    private final actor FixedWorkspaceResolver: WorkspaceResolver {
        private var opened: Set<UUID> = []

        var activeWorkspaceCount: Int { opened.count }

        func workspace(id: UUID) async throws -> (any WorkspaceProvider)? {
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
            WorkspaceReference(id: workspaceID, uri: .threadWorkspace(workspaceID), location: .runtime)
        }

        init(id: UUID) {
            self.workspaceID = id
        }

        func readFile(path: String) async throws -> String { "" }
        func writeFile(path: String, content: String) async throws {}
        func listFiles(path: String) async throws -> [String] { [] }
        func deleteFile(path: String) async throws {}
        func healthCheck() async -> Bool { true }
    }

    @Test("ThreadManager built with a custom WorkspaceResolver creates and hydrates threads")
    func createAndHydrateWithCustomResolver() async throws {
        let workspace = TestWorkspace()

        let manager = ThreadManager(
            stores: .init(
                threadStore: InMemoryThreadPersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence(),
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceProfile: .hostManaged(root: workspace.root),
            resolver: FixedWorkspaceResolver()
        )

        let thread = try await manager.createThread(title: "Custom Resolver Thread")
        #expect(thread.title == "Custom Resolver Thread")
        #expect(await manager.thread(id: thread.id) != nil)

        await manager.evictThreadFromMemory(id: thread.id)
        #expect(await manager.thread(id: thread.id) == nil)

        try await manager.hydrateThread(id: thread.id)
        #expect(await manager.thread(id: thread.id) != nil)
    }
}
