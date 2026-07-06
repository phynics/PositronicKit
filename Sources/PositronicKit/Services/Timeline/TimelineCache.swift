import Foundation
import PKShared

/// Narrow in-memory cache seam used by the extracted `TimelineManager` lifecycle services
/// (`TimelineLifecycleService`, `WorkspaceAttachmentService`) to read and mutate the timeline /
/// tool-manager / context-manager caches that stay owned by `TimelineManager`.
///
/// Each method is an atomic operation that preserves the conditional-write semantics the original
/// in-actor code relied on (e.g. "set timeline only if already present in cache" is a single
/// actor-isolated call, with no `await` between the read and the conditional write).
package protocol TimelineCache: Sendable {
    // MARK: - Timelines

    /// Reads the cached `Timeline` for `id`, if any. Pure read (no `updatedAt` side effect —
    /// that public query behavior lives on `TimelineManager.getTimeline(id:)`).
    func cacheReadTimeline(id: UUID) async -> Timeline?

    /// Returns a snapshot of every `Timeline` currently resident in the cache. Used by
    /// `TimelineLifecycleService.cleanupStaleTimelines(maxAge:)` to scan for stale entries without
    /// the service knowing the cache's identity set.
    func cacheAllTimelineValues() async -> [Timeline]

    /// Unconditionally stores `timeline` in the cache, keyed by its `id`.
    func cacheSetTimeline(_ timeline: Timeline) async

    /// Stores `timeline` only if a timeline with that `id` is already cached. Mirrors the
    /// conditional-write blocks in the original `attachWorkspace`/`updateTimelineTitle`.
    func cacheReplaceTimelineIfPresent(_ timeline: Timeline) async

    // MARK: - Tool managers

    /// Returns `true` if a `TimelineToolManager` is already cached for `id`. Used by
    /// `hydrateTimeline` to short-circuit when the timeline is already resident.
    func cacheHasToolManager(for id: UUID) async -> Bool

    /// Reads the cached `TimelineToolManager` for `id`, if any.
    func cacheReadToolManager(for id: UUID) async -> TimelineToolManager?

    /// Stores `toolManager` for `id` in the cache.
    func cacheSetToolManager(_ toolManager: TimelineToolManager, for id: UUID) async

    // MARK: - Context managers

    /// Stores `contextManager` for `id` in the cache.
    func cacheSetContextManager(_ contextManager: ContextManager, for id: UUID) async

    // MARK: - Eviction

    /// Removes all cached state for `id` — the timeline, tool manager, context manager, and (when
    /// a `TimelinePromptHistoryRegistry` was injected) the journal-diff history entry. Does not
    /// touch persistence. Atomic; mirrors the original `evictTimelineFromMemory(id:)`.
    func cacheEvictAll(id: UUID) async
}

// MARK: - TimelineManager conformance

extension TimelineManager: TimelineCache {
    package func cacheReadTimeline(id: UUID) async -> Timeline? {
        timelines[id]
    }

    package func cacheAllTimelineValues() async -> [Timeline] {
        Array(timelines.values)
    }

    package func cacheSetTimeline(_ timeline: Timeline) async {
        timelines[timeline.id] = timeline
    }

    package func cacheReplaceTimelineIfPresent(_ timeline: Timeline) async {
        guard timelines[timeline.id] != nil else { return }
        timelines[timeline.id] = timeline
    }

    package func cacheHasToolManager(for id: UUID) async -> Bool {
        toolManagers[id] != nil
    }

    package func cacheReadToolManager(for id: UUID) async -> TimelineToolManager? {
        toolManagers[id]
    }

    package func cacheSetToolManager(_ toolManager: TimelineToolManager, for id: UUID) async {
        toolManagers[id] = toolManager
    }

    package func cacheSetContextManager(_ contextManager: ContextManager, for id: UUID) async {
        contextManagers[id] = contextManager
    }

    package func cacheEvictAll(id: UUID) async {
        timelines.removeValue(forKey: id)
        contextManagers.removeValue(forKey: id)
        toolManagers.removeValue(forKey: id)
        await promptHistoryRegistry?.removeHistory(for: id)
    }
}