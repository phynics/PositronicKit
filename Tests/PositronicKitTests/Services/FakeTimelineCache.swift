import Foundation
@testable import PKShared
@testable import PositronicKit

/// In-memory `TimelineCache` fake for the `WorkspaceAttachmentService` and
/// `TimelineLifecycleService` isolation tests (PKARCH-003 AC #2/#3).
///
/// Mirrors the cache shape of `TimelineManager` (`timelines`/`toolManagers`/`contextManagers`
/// dictionaries) without bringing up a real `TimelineManager` or its persistence wiring. Records
/// eviction invocations so tests can assert on them.
actor FakeTimelineCache: TimelineCache {
    private(set) var timelines: [UUID: Timeline] = [:]
    private(set) var toolManagers: [UUID: TimelineToolManager] = [:]
    private(set) var contextManagers: [UUID: ContextManager] = [:]
    private(set) var evictedIds: Set<UUID> = []
    private(set) var evictAllCallCount = 0

    func cacheReadTimeline(id: UUID) async -> Timeline? { timelines[id] }
    func cacheAllTimelineValues() async -> [Timeline] { Array(timelines.values) }
    func cacheSetTimeline(_ timeline: Timeline) async { timelines[timeline.id] = timeline }
    func cacheReplaceTimelineIfPresent(_ timeline: Timeline) async {
        guard timelines[timeline.id] != nil else { return }
        timelines[timeline.id] = timeline
    }
    func cacheHasToolManager(for id: UUID) async -> Bool { toolManagers[id] != nil }
    func cacheReadToolManager(for id: UUID) async -> TimelineToolManager? { toolManagers[id] }
    func cacheSetToolManager(_ toolManager: TimelineToolManager, for id: UUID) async {
        toolManagers[id] = toolManager
    }
    func cacheSetContextManager(_ contextManager: ContextManager, for id: UUID) async {
        contextManagers[id] = contextManager
    }
    func cacheEvictAll(id: UUID) async {
        timelines.removeValue(forKey: id)
        toolManagers.removeValue(forKey: id)
        contextManagers.removeValue(forKey: id)
        evictedIds.insert(id)
        evictAllCallCount += 1
    }
}