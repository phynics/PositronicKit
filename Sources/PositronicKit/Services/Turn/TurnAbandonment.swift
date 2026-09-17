import Foundation
import PKContracts

/// Runtime policy for how an abandoned Turn is interrupted (ADR 0010).
enum TurnAbandonment {
    /// Chooses between a retryable interruption and a quarantine from durable evidence.
    ///
    /// A quarantine is required only when retrying could repeat a side effect: an unresolved tool
    /// intent recorded with `.mutating` or `.externalProcess` side effects. The evidence is read
    /// from the intent itself, so it works even when the Timeline is not hydrated and the tool is
    /// no longer registered in this process. Throws when the store cannot answer, so callers fail
    /// closed instead of interrupting without evidence.
    static func disposition(
        for turnID: UUID,
        repository: any TimelineRuntimeRepository
    ) async throws -> TurnInterruptDisposition {
        let intents = try await repository.fetchToolIntents(turnID: turnID)
        guard !intents.isEmpty else { return .retryable }
        let results = try await repository.fetchToolResults(turnID: turnID)
        let resolved = Set(results.map(\.toolCallID))
        for intent in intents where !resolved.contains(intent.toolCallID) {
            if intent.sideEffects == .mutating || intent.sideEffects == .externalProcess {
                return .quarantined("Unresolved tool intent \(intent.toolCallID) for a side-effecting tool.")
            }
        }
        return .retryable
    }
}