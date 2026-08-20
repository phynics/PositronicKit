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
/// Semantics are preserved exactly from the prior per-provider implementations:
/// - `shouldRetry(error:)` returns `true` only when the error is transient **and** nothing
///   has been yielded yet.
/// - `markYieldedIfNeeded(_:)` flips the gate the first time a chunk carries non-empty
///   `content`, non-empty `reasoning`, or any (non-`nil`) `toolCalls` delta.
public final class DuplicateContentRetryGate: Sendable {
    private let hasYielded = Mutex(false)

    public init() {}

    /// Returns `true` if the error is transient AND no content has been yielded yet.
    public func shouldRetry(error: Error) -> Bool {
        hasYielded.withLock { yielded in
            !yielded && RetryPolicy.isTransient(error: error)
        }
    }

    /// Marks the gate as yielded if the chunk carries non-empty content/reasoning or any
    /// tool-call delta. Once yielded, subsequent calls are no-ops and `shouldRetry` will
    /// always return `false`.
    public func markYieldedIfNeeded(_ chunk: LLMStreamChunk) {
        hasYielded.withLock { yielded in
            if yielded { return }
            guard let delta = chunk.choices.first?.delta else { return }
            if delta.content?.isEmpty == false
                || delta.reasoning?.isEmpty == false
                || delta.toolCalls != nil {
                yielded = true
            }
        }
    }
}
