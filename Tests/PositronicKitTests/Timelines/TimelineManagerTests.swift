import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

@Suite(.tags(.integration))
struct TimelineManagerTests {
    @Test("manager parameter labels remain source compatible")
    func managerParameterLabels() async throws {
        let manager = TimelineManager(workspaceProfile: .noWorkspace)
        let timeline = try await manager.createTimeline(title: "Legacy labels")

        _ = try await manager.getHistory(for: timeline.id)
        _ = await manager.enabledTools(for: timeline.id)
        _ = await manager.enableTool(id: "missing", for: timeline.id)
        _ = await manager.disableTool(id: "missing", for: timeline.id)
        #expect(try await manager.getToolSource(toolName: "missing", for: timeline.id) == nil)

        let task = Task<Void, Never> {}
        let requestID = UUID()
        await manager.registerTask(task, turnID: requestID, for: timeline.id)
        _ = await manager.cancelGeneration(turnID: requestID, for: timeline.id)
        await manager.cancelGeneration(for: timeline.id)
        await manager.removeTask(turnID: requestID, for: timeline.id)
        await manager.cancelActiveTaskAndAwait(for: timeline.id)
    }

    @Test("attachment parameter labels remain source compatible")
    func attachmentParameterLabels() async throws {
        let manager = TimelineManager(workspaceProfile: .noWorkspace)
        let timeline = try await manager.createTimeline(title: "Legacy attachments")
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(parsing: "workspace://legacy-labels")!,
            location: .attached
        )
        try await manager.importWorkspace(workspace)

        try await manager.attachWorkspace(workspace.id, to: timeline.id)
        #expect(try await manager.getWorkspaces(for: timeline.id).attached.map(\.id) == [workspace.id])
        try await manager.detachWorkspace(workspace.id, from: timeline.id)
        #expect(try await manager.getWorkspaces(for: timeline.id).attached.isEmpty)
    }

    @Test("canonical timeline manager owns lifecycle and policy surface")
    func canonicalTimelineManagerSurface() async throws {
        let persistence = MockPersistenceService()
        let timelineStore = MockTimelinePersistence()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: timelineStore,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: InMemoryTimelineRuntimeRepository(),
                toolPersistence: persistence
            ),
            workspaceProfile: .noWorkspace
        )

        let workspace = WorkspaceReference(
            id: UUID(),
            uri: WorkspaceURI(parsing: "workspace://canonical")!,
            location: .attached
        )
        try await manager.importWorkspace(workspace)

        let timeline = try await manager.createTimeline(title: "Lifecycle")
        #expect(await manager.timeline(id: timeline.id)?.id == timeline.id)

        try await manager.updateTimelineTitle(timeline.id, title: "Renamed")
        try await manager.attachWorkspace(workspace.id, to: timeline.id)
        let result = await manager.deleteTimelinePermanently(id: timeline.id)

        #expect(result.timelineID == timeline.id)
    }

    @Test("canonical timeline manager exposes store and runtime policy names")
    func canonicalTimelineManagerTypes() {
        let policy = RuntimeToolPolicy(
            installTimelineObservationTools: false,
            installsTimelineSendTool: false
        )
        #expect(policy.installTimelineObservationTools == false)
        #expect(policy.installsTimelineSendTool == false)

        let workspaceStore = InMemoryWorkspacePersistence()
        let stores = TimelineManager.Stores(
            timelineStore: InMemoryTimelinePersistence(),
            messageStore: InMemoryMessageStore(),
            workspaceStore: workspaceStore,
            workspaceBindingRepository: workspaceStore,
            runtimeRepository: InMemoryTimelineRuntimeRepository(),
            toolPersistence: InMemoryToolPersistence()
        )
        _ = stores.timelineStore
    }

    @Test("importWorkspace persists into the store the manager validates against")
    func importWorkspacePersistsIntoBackingStore() async throws {
        let store = InMemoryWorkspacePersistence()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: InMemoryTimelinePersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: store,
                workspaceBindingRepository: store,
                runtimeRepository: InMemoryTimelineRuntimeRepository(),
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceProfile: .noWorkspace
        )
        let reference = WorkspaceReference(
            id: UUID(),
            uri: WorkspaceURI(parsing: "workspace://import")!,
            location: .runtime
        )
        try await manager.importWorkspace(reference)
        // A subsequent attachWorkspace must no longer fail the store gate, and the
        // reference is visible via the manager's store.
        #expect(try await store.fetchWorkspace(id: reference.id, includeTools: false) != nil)
    }

    @Test("Test Session Creation")
    func sessionCreation() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: workspace.root))

        let session = try await timelineManager.createTimeline()

        #expect(session.id != UUID(), "Session should have an ID")

        let retrievedSession = await timelineManager.timeline(id: session.id)
        #expect(retrievedSession != nil, "Should be able to retrieve created session")
        #expect(retrievedSession?.id == session.id)

    }

    @Test("Test Stale Session Cleanup")
    func cleanup() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: workspace.root))

        let session = try await timelineManager.createTimeline()

        await timelineManager.cleanupStaleTimelines(maxAge: 0)

        let retrieved = await timelineManager.timeline(id: session.id)
        #expect(retrieved == nil, "Session should be cleaned up")
    }

    @Test("evictTimelineFromMemory(id:) evicts the prompt-history registry entry, not just the cache")
    func deleteTimelineEvictsPromptHistory() async throws {
        let workspace = TestWorkspace()
        let registry = TimelinePromptJournals()
        let timelineManager = TimelineManager(
            workspaceProfile: .hostManaged(root: workspace.root),
            promptHistoryRegistry: registry
        )

        let session = try await timelineManager.createTimeline()

        // Populate the registry with distinguishing state.
        let history = await registry.history(for: session.id)
        await history.recordAppend(messageCount: 3, estimatedTokens: 90)
        #expect(await history.appendedMessageCount == 3)

        // evictTimelineFromMemory is the runtime-eviction seam: cache + registry.
        await timelineManager.evictTimelineFromMemory(id: session.id)

        // Cache evicted.
        #expect(await timelineManager.timeline(id: session.id) == nil)

        // Registry evicted — re-fetch yields a fresh instance with reset state.
        let fresh = await registry.history(for: session.id)
        #expect(await fresh.appendedMessageCount == 0)
        #expect(await fresh.appendedTokens == 0)
        #expect(await fresh.lastDiff == nil)
    }

    @Test("cleanupStaleTimelines(maxAge:) also drops the prompt-history registry entry")
    func cleanupStaleEvictsPromptHistory() async throws {
        let workspace = TestWorkspace()
        let registry = TimelinePromptJournals()
        let timelineManager = TimelineManager(
            workspaceProfile: .hostManaged(root: workspace.root),
            promptHistoryRegistry: registry
        )

        let session = try await timelineManager.createTimeline()

        let history = await registry.history(for: session.id)
        await history.recordAppend(messageCount: 5, estimatedTokens: 150)
        #expect(await history.appendedMessageCount == 5)

        await timelineManager.cleanupStaleTimelines(maxAge: 0)

        #expect(await timelineManager.timeline(id: session.id) == nil)

        let fresh = await registry.history(for: session.id)
        #expect(await fresh.appendedMessageCount == 0)
        #expect(await fresh.appendedTokens == 0)
    }

    @Test("evictTimelineFromMemory(id:) with no injected registry still evicts the cache")
    func deleteTimelineWithoutRegistry() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: workspace.root))

        let session = try await timelineManager.createTimeline()

        await timelineManager.evictTimelineFromMemory(id: session.id)

        #expect(await timelineManager.timeline(id: session.id) == nil)
    }

    @Test("Test Task Registration and Cancellation")
    func taskCancellation() async {
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: workspaceRoot))
        let timelineID = UUID()

        let isCancelled = Mutex(false)

        let (waitStream, waitContinuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            await withTaskCancellationHandler {
                var iterator = waitStream.makeAsyncIterator()
                _ = await iterator.next()
            } onCancel: {
                isCancelled.withLock { $0 = true }
            }
        }

        await timelineManager.registerTask(task, turnID: UUID(), for: timelineID)

        // Verify it's in the registry (using internal access if possible, or just through behavior)
        await timelineManager.cancelGeneration(for: timelineID)

        waitContinuation.finish()
        _ = await task.value

        let cancelledFinal = isCancelled.withLock { $0 }
        #expect(cancelledFinal, "Task should have been cancelled")
    }

    @Test("hydrateTimeline short-circuits when a tool manager is already cached")
    func hydrateShortCircuit() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let timeline = try await timelineManager.createTimeline()
        try await persistence.deleteTimeline(id: timeline.id)

        try await timelineManager.hydrateTimeline(id: timeline.id)
        #expect(await timelineManager.timeline(id: timeline.id) != nil)
    }

    @Test("hydrateTimeline throws timelineNotFound when persistence has no timeline")
    func hydrateMissing() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: workspace.root))

        do {
            try await timelineManager.hydrateTimeline(id: UUID())
            Issue.record("Expected timelineNotFound")
        } catch TimelineError.timelineNotFound {
            // ok
        }
    }

    @Test("updateTimelineTitle mutates cache and persistence")
    func updateTitle() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let timeline = try await timelineManager.createTimeline()

        try await timelineManager.updateTimelineTitle(timeline.id, title: "renamed")

        let cached = try #require(await timelineManager.timeline(id: timeline.id))
        #expect(cached.title == "renamed")
        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.title == "renamed")
    }

    @Test("updateTimelineTitle for a missing timeline throws timelineNotFound")
    func updateTitleMissing() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: workspace.root))

        do {
            try await timelineManager.updateTimelineTitle(UUID(), title: "x")
            Issue.record("Expected timelineNotFound")
        } catch TimelineError.timelineNotFound {
            // ok
        }
    }

    @Test("cleanupStaleTimelines evicts from memory but not persistence")
    func cleanupStaleDoesNotPersistDelete() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let timeline = try await timelineManager.createTimeline()

        await timelineManager.cleanupStaleTimelines(maxAge: 0)

        #expect(await timelineManager.timeline(id: timeline.id) == nil)
        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.id == timeline.id)
    }

    @Test("createTimeline creates Notes/Welcome.md and Notes/Project.md in the working directory")
    func createTimelineWritesDefaultNotes() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: workspace.root))

        let timeline = try await timelineManager.createTimeline()

        let workingDir = try #require(timeline.workingDirectory)
        let notesDir = URL(fileURLWithPath: workingDir).appendingPathComponent("Notes")
        let welcome = try String(
            contentsOf: notesDir.appendingPathComponent("Welcome.md"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: notesDir.appendingPathComponent("Project.md"),
            encoding: .utf8
        )
        #expect(welcome.contains("Welcome"))
        #expect(project.contains("Active Objective"))
    }

    // Note: the four `createToolManager` policy tests previously here were migrated to
    // `RuntimeToolPolicyFactoryTests` (under `Tests/PositronicKitTests/Services/`), which
    // exercises the extracted `RuntimeToolPolicyFactory` directly with in-memory stores —
    // satisfying PKARCH-003 AC #4 without needing a `TimelineManager` instance.
}
