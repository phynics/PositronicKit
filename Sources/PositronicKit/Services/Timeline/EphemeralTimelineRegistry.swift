import Foundation
import Synchronization

/// Process-local registry of ephemeral Timeline lifetimes owned by one runtime identity.
///
/// A fork returns an ordinary ``TimelineHandle`` for an ephemeral Timeline. The handle carries an
/// ``EphemeralTimelineToken``; the runtime deletes the Timeline and its history once the last
/// token for it is released. The registry is the runtime's record of which ephemeral Timelines
/// still have live handles, so a later ``TimelineCapability/open(_:)`` of the same Timeline joins
/// the same lifetime instead of starting a new one.
///
/// Ownership is explicit: the registry holds the ``EphemeralTimelineLease`` (the counter), while
/// each handle holds a token. Dropping the last token releases the Timeline. The cleanup task is
/// spawned from the token's `deinit` because a value-typed handle cannot own asynchronous
/// lifetime work. The closure captures the runtime's ``TimelineManager``, not the runtime
/// itself, so the registry never retains the facade through a lease.
final class EphemeralTimelineRegistry: Sendable {
    private let state = Mutex<[UUID: EphemeralTimelineLease]>([:])

    init() {}

    /// Registers one ephemeral Timeline and the cleanup to run when its last handle is released.
    ///
    /// Registering an existing Timeline replaces nothing: the caller creates each ephemeral
    /// Timeline once. The cleanup runs before the registry forgets the Timeline, so an observer
    /// that sees ``contains(_:) == false`` knows deletion finished.
    func register(timelineID: UUID, cleanup: @escaping @Sendable (UUID) async -> Void) {
        let lease = EphemeralTimelineLease(timelineID: timelineID) { [weak self] id in
            await cleanup(id)
            self?.remove(timelineID: id)
        }
        state.withLock { $0[timelineID] = lease }
    }

    /// Returns a fresh handle token for the ephemeral Timeline, or `nil` when it is not ephemeral.
    ///
    /// Each call adds one live handle. The token's `deinit` removes it, and the Timeline is
    /// deleted when the count reaches zero.
    func token(for timelineID: UUID) -> EphemeralTimelineToken? {
        state.withLock { $0[timelineID] }?.makeToken()
    }

    /// Whether the ephemeral Timeline still has a registered lifetime.
    func contains(_ timelineID: UUID) -> Bool {
        state.withLock { $0[timelineID] != nil }
    }

    private func remove(timelineID: UUID) {
        _ = state.withLock { $0.removeValue(forKey: timelineID) }
    }
}

/// Reference-counted lifetime of one ephemeral Timeline.
///
/// The lease lives as long as the registry entry. Handles join it by taking a
/// ``EphemeralTimelineToken``; the release of the last token schedules ``onLastRelease`` exactly
/// once. The lease state is synchronous, so a release that races a join is serialized by the
/// mutex without an actor hop.
private final class EphemeralTimelineLease: Sendable {
    private struct State {
        var liveHandles = 0
        var didRelease = false
    }

    private let state = Mutex(State())
    private let timelineID: UUID
    private let onLastRelease: @Sendable (UUID) async -> Void

    init(timelineID: UUID, onLastRelease: @escaping @Sendable (UUID) async -> Void) {
        self.timelineID = timelineID
        self.onLastRelease = onLastRelease
    }

    func makeToken() -> EphemeralTimelineToken {
        state.withLock { $0.liveHandles += 1 }
        return EphemeralTimelineToken(lease: self)
    }

    fileprivate func release() {
        let shouldCleanup = state.withLock { state -> Bool in
            state.liveHandles -= 1
            guard state.liveHandles <= 0, !state.didRelease else { return false }
            state.didRelease = true
            return true
        }
        guard shouldCleanup else { return }
        let timelineID = timelineID
        let onLastRelease = onLastRelease
        Task {
            await onLastRelease(timelineID)
        }
    }
}

/// One live handle's claim on an ephemeral Timeline.
///
/// Handles are value types, so a copied ``TimelineHandle`` shares one token and contributes one
/// claim: the lifetime ends only after every copy of every handed-out handle is released.
final class EphemeralTimelineToken: Sendable {
    private let lease: EphemeralTimelineLease

    fileprivate init(lease: EphemeralTimelineLease) {
        self.lease = lease
    }

    deinit {
        lease.release()
    }
}
