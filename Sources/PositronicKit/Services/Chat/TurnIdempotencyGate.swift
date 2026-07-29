import Foundation

// MARK: - Turn Idempotency Gate

actor TurnIdempotencyGate {
    static let shared = TurnIdempotencyGate()

    private var processedSendIds: Set<UUID> = []

    private init() {}

    /// Marks `sendId` as in-progress. Returns `true` if newly marked, `false` if already
    /// processed or in progress.
    func checkAndMark(sendId: UUID) -> Bool {
        guard !processedSendIds.contains(sendId) else { return false }
        processedSendIds.insert(sendId)
        return true
    }

    /// Releases the idempotency marker so the caller can retry with the same `sendId`.
    func release(sendId: UUID) {
        processedSendIds.remove(sendId)
    }
}
