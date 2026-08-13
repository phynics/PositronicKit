import Foundation

/// Send-scoped registry of the active stream-driving task for each timeline.
///
/// Each `ChatEngine.execute(...)` send registers its stream-driving `Task` here, keyed by
/// `(threadID, sendID)`. Terminal paths remove the entry only when the sendID still matches
/// the active one, so a stale send cannot evict or cancel a newer send.
/// ``ThreadDriver/cancel()`` cancels whatever task is currently active for the thread;
/// eviction/deletion cancels and awaits bounded cleanup via ``cancelAndAwait(for:)``.
public actor ThreadTaskRegistry {
    public init() {}
    struct ActiveSend: Sendable {
        let sendID: UUID
        let task: Task<Void, Never>
    }

    private var active: [UUID: ActiveSend] = [:]

    /// Registers the stream-driving task for a send, cancelling any previously active task
    /// for the same timeline (replacement-send behavior).
    func register(_ task: Task<Void, Never>, sendID: UUID, for threadID: UUID) {
        active[threadID]?.task.cancel()
        active[threadID] = ActiveSend(sendID: sendID, task: task)
    }

    /// Cancels whatever task is currently active for the timeline (used by
    /// ``TimelineDriver/cancel()``). No-op if no send is active. The entry is removed by the
    /// task's own terminal path via ``removeIfActive(sendID:for:)``.
    func cancelActive(for threadID: UUID) {
        active[threadID]?.task.cancel()
    }

    /// Send-scoped cancellation: only cancels if `sendID` is still the active send for this
    /// timeline. Returns `false` (no-op) for a stale send that has been superseded by a newer
    /// one.
    @discardableResult
    func cancel(sendID: UUID, for threadID: UUID) -> Bool {
        guard let current = active[threadID], current.sendID == sendID else { return false }
        current.task.cancel()
        return true
    }

    /// Removes the entry on a terminal path, but only if `sendID` is still the active send.
    /// A stale send (superseded by a newer one) is a no-op so it cannot evict the newer send's
    /// entry.
    func removeIfActive(sendID: UUID, for threadID: UUID) {
        guard let current = active[threadID], current.sendID == sendID else { return }
        active.removeValue(forKey: threadID)
    }

    /// Cancels any active task for the timeline and awaits its termination (bounded cleanup
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

    /// Whether a send is currently active for the timeline.
    func hasActiveSend(for threadID: UUID) -> Bool {
        active[threadID] != nil
    }
}
