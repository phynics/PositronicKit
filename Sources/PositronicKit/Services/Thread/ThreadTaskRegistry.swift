import Foundation

/// Turn-scoped registry of the active stream-driving task for each thread.
///
/// Each `TurnEngine.execute(...)` turn registers its stream-driving `Task` here, keyed by
/// `(threadID, turnID)`. Terminal paths remove the entry only when the turnID still matches
/// the active one, so a stale turn cannot evict or cancel a newer turn.
/// ``ThreadDriver/cancel()`` cancels whatever task is currently active for the thread;
/// eviction/deletion cancels and awaits bounded cleanup via `cancelAndAwait(for:)`.
public actor ThreadTaskRegistry {
    public init() {}
    struct ActiveTurn: Sendable {
        let turnID: UUID
        let task: Task<Void, Never> // swiftlint:disable:this concurrency_stored_task -- owned by actor/@MainActor (see docs/Concurrency/exception-manifest.md)
    }

    private var active: [UUID: ActiveTurn] = [:]

    /// Registers the stream-driving task for a send, cancelling any previously active task
    /// for the same thread (replacement-send behavior).
    func register(_ task: Task<Void, Never>, turnID: UUID, for threadID: UUID) {
        active[threadID]?.task.cancel()
        active[threadID] = ActiveTurn(turnID: turnID, task: task)
    }

    /// Cancels whatever task is currently active for the thread (used by
    /// ``ThreadDriver/cancel()``). No-op if no turn is active. The entry is removed by the
    /// task's own terminal path via ``removeIfActive(turnID:for:)``.
    func cancelActive(for threadID: UUID) {
        active[threadID]?.task.cancel()
    }

    /// Turn-scoped cancellation: only cancels if `turnID` is still the active turn for this
    /// thread. Returns `false` (no-op) for a stale turn that has been superseded by a newer one.
    @discardableResult
    func cancel(turnID: UUID, for threadID: UUID) -> Bool {
        guard let current = active[threadID], current.turnID == turnID else { return false }
        current.task.cancel()
        return true
    }

    /// Removes the entry on a terminal path, but only if `turnID` is still the active turn.
    /// A stale turn (superseded by a newer one) is a no-op so it cannot evict the newer turn's
    /// entry.
    func removeIfActive(turnID: UUID, for threadID: UUID) {
        guard let current = active[threadID], current.turnID == turnID else { return }
        active.removeValue(forKey: threadID)
    }

    /// Cancels any active task for the thread and awaits its termination (bounded cleanup
    /// for eviction/deletion). The task's own cancellation handling (stream timeout,
    /// `Task.checkCancellation` checkpoints) bounds how long this awaits.
    func cancelAndAwait(for threadID: UUID) async {
        guard let current = active[threadID] else { return }
        current.task.cancel()
        _ = await current.task.value
        active.removeValue(forKey: threadID)
    }

    /// Returns a non-mutating snapshot of the currently registered task for joining.
    func activeTaskCompletion(for threadID: UUID) -> Task<Void, Never>? {
        active[threadID]?.task
    }

    /// Whether a send is currently active for the thread.
    func hasActiveTurn(for threadID: UUID) -> Bool {
        active[threadID] != nil
    }
}
