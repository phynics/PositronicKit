import Foundation
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

/// Isolation tests for `TimelineLifecycleService` (PKARCH-003 AC #2): create / hydrate / evict /
/// cleanup, exercising the service directly with `MockPersistenceService` + `FakeTimelineCache`
/// and no `TimelineManager`.
@Suite("TimelineLifecycleService isolation")
struct TimelineLifecycleServiceIsolationTests {
    private struct Setup {
        let cache: FakeTimelineCache
        let persistence: MockPersistenceService
        let workspaceRoot: URL
        let service: TimelineLifecycleService
    }

    private static func make(
        runtimeToolPolicy: TimelineManager.RuntimeToolPolicy = .default
    ) async -> Setup {
        let cache = FakeTimelineCache()
        let persistence = MockPersistenceService()
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)

        let workspaceManager = WorkspaceManager(
            repository: AgentWorkspaceService(
                workspaceRoot: workspaceRoot,
                workspacePersistence: persistence
            ),
            workspaceCreator: NullWorkspaceCreator()
        )

        let service = TimelineLifecycleService(
            cache: cache,
            timelineStore: persistence,
            messageStore: persistence,
            workspaceStore: persistence,
            workspaceManager: workspaceManager,
            memoryStore: persistence,
            embeddingService: NoOpEmbeddingService(),
            workspaceRoot: workspaceRoot,
            promptHistoryRegistry: nil,
            runtimeToolPolicy: runtimeToolPolicy
        )

        return Setup(
            cache: cache,
            persistence: persistence,
            workspaceRoot: workspaceRoot,
            service: service
        )
    }

    @Test("createTimeline persists the timeline and caches a toolManager + contextManager")
    func createTimeline() async throws {
        let s = await Self.make()

        let timeline = try await s.service.createTimeline()

        let persisted = try #require(await s.persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.id == timeline.id)
        #expect(!persisted.attachedWorkspaceIds.isEmpty)
        #expect(await s.cache.cacheHasToolManager(for: timeline.id))
        // Cache state lives in the FakeTimelineCache actor; assert through its exposed snapshots.
        #expect(await s.cache.evictAllCallCount == 0)
    }

    @Test("hydrateTimeline short-circuits when a tool manager is already cached")
    func hydrateShortCircuit() async throws {
        let s = await Self.make()
        let timelineId = UUID()
        // Pre-seed cache so the early `cacheHasToolManager` check returns true.
        await s.cache.cacheSetToolManager(
            TimelineToolManager(availableTools: [], timelineContext: nil),
            for: timelineId
        )

        try await s.service.hydrateTimeline(id: timelineId)
        // Hydration took the early return; no timeline was populated because no persistence
        // entry was needed for the short-circuit branch.
        #expect(await s.cache.cacheReadTimeline(id: timelineId) == nil)
    }

    @Test("hydrateTimeline throws timelineNotFound when persistence has no timeline for the id")
    func hydrateMissing() async throws {
        let s = await Self.make()
        do {
            try await s.service.hydrateTimeline(id: UUID())
            Issue.record("Expected timelineNotFound")
        } catch TimelineError.timelineNotFound {
            // ok
        }
    }

    @Test("hydrateTimeline re-populates cache from persistence")
    func hydratePopulatesCache() async throws {
        let s = await Self.make()
        let timeline = try await s.service.createTimeline()
        // Drop the cache state, simulating a memory eviction between runs.
        await s.cache.cacheEvictAll(id: timeline.id)
        // Persist the timeline explicitly (createTimeline already did, but the runtime workspace
        // save happens against `workspaceStore`, which `MockPersistenceService` shares with
        // `timelineStore` via the unify-everything adapter; the persisted timeline is still there).
        let persisted = try #require(await s.persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.id == timeline.id)

        try await s.service.hydrateTimeline(id: timeline.id)
        #expect(await s.cache.cacheReadTimeline(id: timeline.id) != nil)
        #expect(await s.cache.cacheHasToolManager(for: timeline.id))
    }

    @Test("updateTimelineTitle mutates cache and persistence")
    func updateTitle() async throws {
        let s = await Self.make()
        let timeline = try await s.service.createTimeline()

        try await s.service.updateTimelineTitle(id: timeline.id, title: "renamed")

        let cached = try #require(await s.cache.cacheReadTimeline(id: timeline.id))
        #expect(cached.title == "renamed")
        let persisted = try #require(await s.persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.title == "renamed")
    }

    @Test("updateTimelineTitle for a missing timeline throws timelineNotFound")
    func updateTitleMissing() async throws {
        let s = await Self.make()
        do {
            try await s.service.updateTimelineTitle(id: UUID(), title: "x")
            Issue.record("Expected timelineNotFound")
        } catch TimelineError.timelineNotFound {
            // ok
        }
    }

    @Test("deleteTimeline evicts cache state and does not touch persistence")
    func deleteEvicts() async throws {
        let s = await Self.make()
        let timeline = try await s.service.createTimeline()

        await s.service.deleteTimeline(id: timeline.id)

        #expect(await s.cache.evictedIds.contains(timeline.id))
        #expect(await s.cache.cacheReadTimeline(id: timeline.id) == nil)
        #expect(await s.cache.cacheReadToolManager(for: timeline.id) == nil)
        let stillPersisted = try #require(await s.persistence.fetchTimeline(id: timeline.id))
        #expect(stillPersisted.id == timeline.id)
    }

    @Test("cleanupStaleTimelines evicts only timelines older than maxAge")
    func cleanupStaleTimelines() async throws {
        let s = await Self.make()
        let nova = try await s.service.createTimeline()
        var aged = try #require(await s.cache.cacheReadTimeline(id: nova.id))
        aged.updatedAt = Date().addingTimeInterval(-10)
        await s.cache.cacheSetTimeline(aged)

        let fresh = try await s.service.createTimeline()

        await s.service.cleanupStaleTimelines(maxAge: 1)

        #expect(await s.cache.evictedIds.contains(nova.id))
        #expect(await s.cache.evictedIds.contains(fresh.id) == false)
        #expect(await s.cache.cacheReadTimeline(id: nova.id) == nil)
        #expect(await s.cache.cacheReadTimeline(id: fresh.id) != nil)
    }

    @Test("cached eviction does not delete persisted timelines (cleanupStaleTimelines)")
    func cleanupStaleDoesNotPersistDelete() async throws {
        let s = await Self.make()
        let timeline = try await s.service.createTimeline()

        await s.service.cleanupStaleTimelines(maxAge: 0)

        #expect(await s.cache.evictedIds.contains(timeline.id))
        let persisted = try #require(await s.persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.id == timeline.id)
    }

    @Test("writeDefaultNotes creates Notes/Welcome.md and Notes/Project.md")
    func writeDefaultNotes() async throws {
        let s = await Self.make()
        let url = s.workspaceRoot.appendingPathComponent(UUID().uuidString)
        try await s.service.writeDefaultNotes(at: url)

        let welcome = try String(
            contentsOf: url.appendingPathComponent("Notes").appendingPathComponent("Welcome.md"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: url.appendingPathComponent("Notes").appendingPathComponent("Project.md"),
            encoding: .utf8
        )
        #expect(welcome.contains("Welcome"))
        #expect(project.contains("Active Objective"))
    }
}