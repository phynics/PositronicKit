import Foundation

/// Turn-scoped registry of the active stream-driving task for each timeline.
///
/// Each `TurnEngine.execute(...)` turn registers its stream-driving `Task` here, keyed by
/// `(timelineID, turnID)`. Terminal paths remove the entry only when the turnID still matches
/// the active one, so a stale turn cannot evict or cancel a newer turn.
/// ``TimelineHandle/cancel()`` cancels whatever task is currently active for the timeline;
/// eviction/deletion cancels and awaits bounded cleanup via `cancelAndAwait(for:)`.
actor TimelineTaskRegistry {
    public init() {}
    struct ActiveTurn: Sendable {
        let turnID: UUID
        let task: Task<Void, Never> // swiftlint:disable:this concurrency_stored_task -- owned by actor/@MainActor (see docs/Concurrency/exception-manifest.md)
    }

    private var active: [UUID: ActiveTurn] = [:]

    /// Registers the stream-driving task for a Turn without replacing another active Turn.
    @discardableResult
    func register(_ task: Task<Void, Never>, turnID: UUID, for timelineID: UUID) -> Bool {
        guard active[timelineID] == nil else { return false }
        active[timelineID] = ActiveTurn(turnID: turnID, task: task)
        return true
    }

    /// Cancels whatever task is currently active for the timeline (used by
    /// ``TimelineHandle/cancel()``). No-op if no turn is active. The entry is removed by the
    /// task's own terminal path via ``removeIfActive(turnID:for:)``.
    func cancelActive(for timelineID: UUID) {
        active[timelineID]?.task.cancel()
    }

    /// Turn-scoped cancellation: only cancels if `turnID` is still the active turn for this
    /// timeline. Returns `false` (no-op) for a stale turn that has been superseded by a newer one.
    @discardableResult
    func cancel(turnID: UUID, for timelineID: UUID) -> Bool {
        guard let current = active[timelineID], current.turnID == turnID else { return false }
        current.task.cancel()
        return true
    }

    /// Removes the entry on a terminal path, but only if `turnID` is still the active turn.
    /// A stale turn (superseded by a newer one) is a no-op so it cannot evict the newer turn's
    /// entry.
    func removeIfActive(turnID: UUID, for timelineID: UUID) {
        guard let current = active[timelineID], current.turnID == turnID else { return }
        active.removeValue(forKey: timelineID)
    }

    /// Cancels any active task for the timeline and awaits its termination (bounded cleanup
    /// for eviction/deletion). The task's own cancellation handling (stream timeout,
    /// `Task.checkCancellation` checkpoints) bounds how long this awaits.
    func cancelAndAwait(for timelineID: UUID) async {
        guard let current = active[timelineID] else { return }
        current.task.cancel()
        _ = await current.task.value
        active.removeValue(forKey: timelineID)
    }

    /// Returns a non-mutating snapshot of the currently registered task for joining.
    func activeTaskCompletion(for timelineID: UUID) -> Task<Void, Never>? {
        active[timelineID]?.task
    }

    /// Whether a send is currently active for the timeline.
    func hasActiveTurn(for timelineID: UUID) -> Bool {
        active[timelineID] != nil
    }
}
