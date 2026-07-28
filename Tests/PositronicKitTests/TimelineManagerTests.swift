import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

struct TimelineManagerTests {
    @Test("Test Session Creation and Turn Briefing Builder Access")
    func sessionCreation() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)

        let session = try await timelineManager.createTimeline()

        #expect(session.id != UUID(), "Session should have an ID")

        let retrievedSession = await timelineManager.timeline(id: session.id)
        #expect(retrievedSession != nil, "Should be able to retrieve created session")
        #expect(retrievedSession?.id == session.id)

        // Verify TurnBriefingBuilder is created and has access to workspace
        let turnBriefingBuilder = await timelineManager.getTurnBriefingBuilder(for: session.id)
        #expect(turnBriefingBuilder != nil, "TurnBriefingBuilder should be created for session")
    }

    @Test("Test Stale Session Cleanup")
    func cleanup() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)

        let session = try await timelineManager.createTimeline()

        await timelineManager.cleanupStaleTimelines(maxAge: 0)

        let retrieved = await timelineManager.timeline(id: session.id)
        #expect(retrieved == nil, "Session should be cleaned up")
    }

    @Test("deleteTimeline(id:) evicts the prompt-history registry entry, not just the cache")
    func deleteTimelineEvictsPromptHistory() async throws {
        let workspace = TestWorkspace()
        let registry = TimelinePromptJournals()
        let timelineManager = TimelineManager(
            workspaceRoot: workspace.root,
            promptHistoryRegistry: registry
        )

        let session = try await timelineManager.createTimeline()

        // Populate the registry with distinguishing state.
        let history = await registry.history(for: session.id)
        await history.recordAppend(messageCount: 3, estimatedTokens: 90)
        #expect(await history.appendedMessageCount == 3)

        // deleteTimeline is the runtime-eviction seam: cache + registry.
        await timelineManager.deleteTimeline(id: session.id)

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
            workspaceRoot: workspace.root,
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

    @Test("deleteTimeline(id:) with no injected registry still evicts the cache")
    func deleteTimelineWithoutRegistry() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)

        let session = try await timelineManager.createTimeline()

        await timelineManager.deleteTimeline(id: session.id)

        #expect(await timelineManager.timeline(id: session.id) == nil)
    }

    @Test("Test Task Registration and Cancellation")
    func taskCancellation() async {
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let timelineManager = TimelineManager(workspaceRoot: workspaceRoot)
        let timelineId = UUID()

        let isCancelled = Mutex(false)

        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            isCancelled.withLock { $0 = true }
        }

        await timelineManager.registerTask(task, sendID: UUID(), for: timelineId)

        // Verify it's in the registry (using internal access if possible, or just through behavior)
        await timelineManager.cancelGeneration(for: timelineId)

        // Poll until the task observes cancellation, with a generous CI-safe deadline
        // (guards only against a genuine hang, not normal scheduling variance).
        let deadline = ContinuousClock.now + .seconds(5)
        while !isCancelled.withLock({ $0 }), ContinuousClock.now < deadline {
            await Task.yield()
        }

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
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let timeline = try await timelineManager.createTimeline()
        try await persistence.deleteTimeline(id: timeline.id)

        try await timelineManager.hydrateTimeline(id: timeline.id)
        #expect(await timelineManager.timeline(id: timeline.id) != nil)
    }

    @Test("hydrateTimeline throws timelineNotFound when persistence has no timeline")
    func hydrateMissing() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)

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
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let timeline = try await timelineManager.createTimeline()

        try await timelineManager.updateTimelineTitle(id: timeline.id, title: "renamed")

        let cached = try #require(await timelineManager.timeline(id: timeline.id))
        #expect(cached.title == "renamed")
        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.title == "renamed")
    }

    @Test("updateTimelineTitle for a missing timeline throws timelineNotFound")
    func updateTitleMissing() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)

        do {
            try await timelineManager.updateTimelineTitle(id: UUID(), title: "x")
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
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
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
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)

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
