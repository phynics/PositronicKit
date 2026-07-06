import Foundation
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

/// Isolation tests for `WorkspaceAttachmentService` (PKARCH-003 AC #2): attach / detach /
/// primary resolution / `.missing` normalization, exercising the service directly with
/// `MockPersistenceService` + `FakeTimelineCache` and no `TimelineManager`.
@Suite("WorkspaceAttachmentService isolation")
struct WorkspaceAttachmentServiceIsolationTests {
    private struct Setup {
        let cache: FakeTimelineCache
        let persistence: MockPersistenceService
        let workspaceRoot: URL
        let service: WorkspaceAttachmentService
        let runtimeWS: WorkspaceReference
        let attachedWS: WorkspaceReference
        let extraWS: WorkspaceReference
    }

    private static func make() async throws -> Setup {
        let cache = FakeTimelineCache()
        let persistence = MockPersistenceService()
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)

        let runtimeWS = WorkspaceReference(
            uri: try #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            rootPath: workspaceRoot.appendingPathComponent("primary").path
        )
        let attachedWS = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        let extraWS = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/lib"),
            location: .attached
        )
        try await persistence.saveWorkspace(runtimeWS)
        try await persistence.saveWorkspace(attachedWS)
        try await persistence.saveWorkspace(extraWS)

        let workspaceManager = WorkspaceManager(
            repository: AgentWorkspaceService(
                workspaceRoot: workspaceRoot,
                workspacePersistence: persistence
            ),
            workspaceCreator: NullWorkspaceCreator()
        )

        let service = WorkspaceAttachmentService(
            cache: cache,
            timelineStore: persistence,
            workspaceStore: persistence,
            workspaceManager: workspaceManager
        )

        return Setup(
            cache: cache,
            persistence: persistence,
            workspaceRoot: workspaceRoot,
            service: service,
            runtimeWS: runtimeWS,
            attachedWS: attachedWS,
            extraWS: extraWS
        )
    }

    @Test("attach to a cached timeline adds the workspace id and writes through to persistence")
    func attachCachedTimeline() async throws {
        let s = try await Self.make()
        let timeline = Timeline(attachedWorkspaceIds: [s.runtimeWS.id])
        await s.cache.cacheSetTimeline(timeline)

        try await s.service.attachWorkspace(s.attachedWS.id, to: timeline.id)

        let persisted = try #require(await s.persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.attachedWorkspaceIds.contains(s.attachedWS.id))
        let cached = try #require(await s.cache.cacheReadTimeline(id: timeline.id))
        #expect(cached.attachedWorkspaceIds.contains(s.attachedWS.id))
    }

    @Test("attach to a non-cached timeline still resolves from persistence")
    func attachUncachedTimeline() async throws {
        let s = try await Self.make()
        let timeline = Timeline(attachedWorkspaceIds: [s.runtimeWS.id])
        try await s.persistence.saveTimeline(timeline)

        try await s.service.attachWorkspace(s.attachedWS.id, to: timeline.id)

        let persisted = try #require(await s.persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.attachedWorkspaceIds.contains(s.attachedWS.id))
    }

    @Test("attach is idempotent: attaching the same workspace twice does not duplicate")
    func attachIsIdempotent() async throws {
        let s = try await Self.make()
        let timeline = Timeline(attachedWorkspaceIds: [s.runtimeWS.id])
        await s.cache.cacheSetTimeline(timeline)

        try await s.service.attachWorkspace(s.attachedWS.id, to: timeline.id)
        try await s.service.attachWorkspace(s.attachedWS.id, to: timeline.id)

        let cached = try #require(await s.cache.cacheReadTimeline(id: timeline.id))
        let matching = cached.attachedWorkspaceIds.filter { $0 == s.attachedWS.id }
        #expect(matching.count == 1)
    }

    @Test("attach to a missing timeline throws timelineNotFound")
    func attachMissingTimeline() async throws {
        let s = try await Self.make()
        let bogus = UUID()
        do {
            try await s.service.attachWorkspace(s.attachedWS.id, to: bogus)
            Issue.record("Expected timelineNotFound")
        } catch TimelineError.timelineNotFound {
            // ok
        }
    }

    @Test("detach removes the workspace id from both cache and persistence")
    func detachRemoves() async throws {
        let s = try await Self.make()
        let timeline = Timeline(attachedWorkspaceIds: [s.runtimeWS.id, s.attachedWS.id])
        await s.cache.cacheSetTimeline(timeline)
        try await s.persistence.saveTimeline(timeline)

        try await s.service.detachWorkspace(s.attachedWS.id, from: timeline.id)

        let cached = try #require(await s.cache.cacheReadTimeline(id: timeline.id))
        #expect(!cached.attachedWorkspaceIds.contains(s.attachedWS.id))
        let persisted = try #require(await s.persistence.fetchTimeline(id: timeline.id))
        #expect(!persisted.attachedWorkspaceIds.contains(s.attachedWS.id))
    }

    @Test("getWorkspaces resolves the runtime workspace as primary")
    func getWorkspacesPrimaryRuntime() async throws {
        let s = try await Self.make()
        let timeline = Timeline(attachedWorkspaceIds: [s.runtimeWS.id, s.attachedWS.id])
        await s.cache.cacheSetTimeline(timeline)

        let resolved = try #require(await s.service.getWorkspaces(for: timeline.id))
        #expect(resolved.primary?.id == s.runtimeWS.id)
        #expect(resolved.attached.contains { $0.id == s.attachedWS.id })
    }

    @Test("getWorkspaces marks a runtime workspace whose root path is missing on disk as .missing")
    func getWorkspacesMissingRuntimeStatus() async throws {
        let s = try await Self.make()
        let ghostRuntime = WorkspaceReference(
            uri: try #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            rootPath: "/path/that/does/not/exist/\(UUID().uuidString)"
        )
        try await s.persistence.saveWorkspace(ghostRuntime)
        let timeline = Timeline(attachedWorkspaceIds: [ghostRuntime.id])
        await s.cache.cacheSetTimeline(timeline)

        let resolved = try #require(await s.service.getWorkspaces(for: timeline.id))
        let primary = try #require(resolved.primary)
        #expect(primary.status == .missing)
    }

    @Test("getWorkspaces for a missing timeline returns nil")
    func getWorkspacesMissingTimeline() async throws {
        let s = try await Self.make()
        let resolved = await s.service.getWorkspaces(for: UUID())
        #expect(resolved == nil)
    }

    @Test("getWorkspace(id:) delegates to the workspace store")
    func getWorkspaceDelegates() async throws {
        let s = try await Self.make()
        let fetched = try #require(await s.service.getWorkspace(s.attachedWS.id))
        #expect(fetched.id == s.attachedWS.id)
    }

    @Test("attach/detach writes to toolManagers only through the cache; no toolManager present means no register call")
    func noToolManagerCacheNoOp() async throws {
        let s = try await Self.make()
        let timeline = Timeline(attachedWorkspaceIds: [s.runtimeWS.id])
        await s.cache.cacheSetTimeline(timeline)

        try await s.service.attachWorkspace(s.attachedWS.id, to: timeline.id)
        #expect(await s.cache.cacheReadToolManager(for: timeline.id) == nil)

        try await s.service.detachWorkspace(s.attachedWS.id, from: timeline.id)
        #expect(await s.cache.cacheReadToolManager(for: timeline.id) == nil)
    }
}