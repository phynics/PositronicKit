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

    /// Turns this process has admitted durably but whose stream-driving task has not been
    /// registered yet (admission precedes task registration by the whole preparation phase).
    /// Liveness classification consults this so an in-flight preparation is never mistaken for
    /// an orphaned Turn from another process (ADR 0010).
    private var admitted: [UUID: UUID] = [:]

    /// Registers the stream-driving task for a Turn without replacing another active Turn.
    /// Marks the admission-to-registration window closed for the timeline.
    @discardableResult
    func register(_ task: Task<Void, Never>, turnID: UUID, for timelineID: UUID) -> Bool {
        guard active[timelineID] == nil else { return false }
        active[timelineID] = ActiveTurn(turnID: turnID, task: task)
        admitted.removeValue(forKey: timelineID)
        return true
    }

    /// Records that this process admitted `turnID` for the timeline. No-op once a task is
    /// registered or another Turn is already admitted; admission is serialized per timeline.
    func markAdmitted(turnID: UUID, for timelineID: UUID) {
        guard active[timelineID] == nil else { return }
        admitted[timelineID] = turnID
    }

    /// Drops the admission marker when preparation fails before a task could register, so a Turn
    /// this process can no longer drive is not mistaken for an in-process owner.
    func removeAdmitted(turnID: UUID, for timelineID: UUID) {
        guard admitted[timelineID] == turnID else { return }
        admitted.removeValue(forKey: timelineID)
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

    /// Cancels any active task for the timeline and awaits its termination for
    /// eviction/deletion. The wait is bounded by the Turn task's own cancellation handling
    /// (stream timeout, `Task.checkCancellation` checkpoints); the terminal commit runs in the
    /// runtime-owned ``TurnFinalizer``, so a hung store commit never extends this wait (ADR 0010).
    func cancelAndAwait(for timelineID: UUID) async {
        admitted.removeValue(forKey: timelineID)
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

    /// The Turn this process is currently driving or preparing for the timeline, or `nil` when it
    /// owns none. Liveness classification uses this to tell an in-process Turn from an orphan.
    func activeTurnID(for timelineID: UUID) -> UUID? {
        active[timelineID]?.turnID ?? admitted[timelineID]
    }
}
