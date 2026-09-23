import Foundation
import PKContracts
import Synchronization

/// Gates retry decisions to prevent retrying after content has been yielded to the consumer.
///
/// Streaming LLM providers must not retry a transient transport error once any chunk has
/// already been emitted to the caller, or the caller would observe duplicated content. This
/// type encapsulates that gate so provider adapters (Ollama, Anthropic, …) share one
/// implementation instead of each carrying their own `Mutex<Bool>` + helper (PKCR-005).
///
/// - `shouldRetry(error:)` returns `true` only when the error is transient **and** nothing
///   has been yielded yet.
/// - `markYieldedIfNeeded(_:)` flips the gate the first time a chunk carries consumer-visible
///   output (see ``PKContracts/LLMStreamChunk/carriesConsumerOutput``).
package final class DuplicateContentRetryGate: Sendable {
    private let hasYielded = Mutex(false)

    package init() {}

    /// Returns `true` if the error is transient AND no content has been yielded yet.
    package func shouldRetry(error: Error) -> Bool {
        hasYielded.withLock { yielded in
            !yielded && RetryPolicy.isTransient(error: error)
        }
    }

    /// Marks the gate as yielded if the chunk carries consumer-visible output. Once yielded,
    /// subsequent calls are no-ops and `shouldRetry` will always return `false`.
    package func markYieldedIfNeeded(_ chunk: LLMStreamChunk) {
        guard chunk.carriesConsumerOutput else { return }
        hasYielded.withLock { $0 = true }
    }
}

extension LLMStreamChunk {
    /// Whether yielding this chunk exposes output a retried request would repeat: non-empty
    /// `content` or `reasoning`, an audio delta, or any tool-call delta.
    ///
    /// Every streaming provider uses this one classification to decide whether a mid-stream
    /// transient error is still safe to retry.
    package var carriesConsumerOutput: Bool {
        guard let delta = choices.first?.delta else { return false }
        return delta.content?.isEmpty == false
            || delta.reasoning?.isEmpty == false
            || delta.audio != nil
            || delta.toolCalls != nil
    }
}
