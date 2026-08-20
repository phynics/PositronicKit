import Foundation

// MARK: - Turn Idempotency Gate

actor TurnIdempotencyGate {
    static let shared = TurnIdempotencyGate()

    private var processedRequestIDs: Set<UUID> = []

    private init() {}

    /// Marks `requestId` as in-progress. Returns `true` if newly marked, `false` if already
    /// processed or in progress.
    func checkAndMark(requestId: UUID) -> Bool {
        guard !processedRequestIDs.contains(requestId) else { return false }
        processedRequestIDs.insert(requestId)
        return true
    }

    /// Releases the idempotency marker so the caller can retry with the same `requestId`.
    func release(requestId: UUID) {
        processedRequestIDs.remove(requestId)
    }
}
