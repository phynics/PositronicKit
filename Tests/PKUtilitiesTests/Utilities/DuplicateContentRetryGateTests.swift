import Foundation
import PKShared
import PKUtilities
import Testing

/// Unit tests for `DuplicateContentRetryGate` (PKCR-005).
///
/// The gate was extracted from near-identical logic previously duplicated in the Ollama and
/// Anthropic provider clients. These tests pin the preserved semantics: retry is allowed only
/// while nothing has been yielded, and the gate flips the first time a chunk carries non-empty
/// `content`, non-empty `reasoning`, or any (non-`nil`) `toolCalls` delta.
@Suite("DuplicateContentRetryGate (PKCR-005)")
struct DuplicateContentRetryGateTests {
    // MARK: - Helpers

    private func makeChunk(
        content: String? = nil,
        reasoning: String? = nil,
        toolCalls: [LLMToolCallDelta]? = nil
    ) -> LLMStreamChunk {
        LLMStreamChunk(
            id: "test",
            model: "test-model",
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(
                    role: .assistant,
                    content: content,
                    reasoning: reasoning,
                    toolCalls: toolCalls
                )
            )]
        )
    }

    private func makeEmptyChoicesChunk() -> LLMStreamChunk {
        LLMStreamChunk(id: "test", model: "test-model", choices: [])
    }

    // MARK: - shouldRetry (pre-yield)

    @Test("Transient error retries when nothing has been yielded")
    func transientErrorRetriesBeforeYield() {
        let gate = DuplicateContentRetryGate()
        #expect(gate.shouldRetry(error: URLError(.timedOut)))
        #expect(gate.shouldRetry(error: LLMServiceError.networkError("boom")))
    }

    @Test("Non-transient error never retries")
    func nonTransientErrorDoesNotRetry() {
        let gate = DuplicateContentRetryGate()
        #expect(!gate.shouldRetry(error: URLError(.badURL)))
        #expect(!gate.shouldRetry(error: LLMServiceError.httpError(
            provider: "test", statusCode: 400, responseBody: "", retryAfter: nil
        )))
    }

    // MARK: - markYieldedIfNeeded: content

    @Test("Non-empty content marks yielded and blocks retry")
    func nonEmptyContentBlocksRetry() {
        let gate = DuplicateContentRetryGate()
        gate.markYieldedIfNeeded(makeChunk(content: "Hello"))
        #expect(!gate.shouldRetry(error: URLError(.timedOut)))
    }

    @Test("Empty content does NOT mark yielded")
    func emptyContentDoesNotMarkYielded() {
        let gate = DuplicateContentRetryGate()
        gate.markYieldedIfNeeded(makeChunk(content: ""))
        #expect(gate.shouldRetry(error: URLError(.timedOut)))
    }

    // MARK: - markYieldedIfNeeded: reasoning

    @Test("Non-empty reasoning marks yielded and blocks retry")
    func nonEmptyReasoningBlocksRetry() {
        let gate = DuplicateContentRetryGate()
        gate.markYieldedIfNeeded(makeChunk(reasoning: "thinking…"))
        #expect(!gate.shouldRetry(error: URLError(.timedOut)))
    }

    @Test("Empty reasoning does NOT mark yielded")
    func emptyReasoningDoesNotMarkYielded() {
        let gate = DuplicateContentRetryGate()
        gate.markYieldedIfNeeded(makeChunk(reasoning: ""))
        #expect(gate.shouldRetry(error: URLError(.timedOut)))
    }

    // MARK: - markYieldedIfNeeded: tool calls

    @Test("Non-nil toolCalls (even empty) marks yielded and blocks retry")
    func nonNilToolCallsBlocksRetry() {
        let gate = DuplicateContentRetryGate()
        // Empty array is non-nil → preserves the prior `toolCalls != nil` semantics.
        gate.markYieldedIfNeeded(makeChunk(toolCalls: []))
        #expect(!gate.shouldRetry(error: URLError(.timedOut)))
    }

    @Test("Populated toolCalls marks yielded and blocks retry")
    func populatedToolCallsBlocksRetry() {
        let gate = DuplicateContentRetryGate()
        gate.markYieldedIfNeeded(makeChunk(toolCalls: [
            LLMToolCallDelta(index: 0, id: "call-1", function: .init(name: "foo", arguments: "{}"))
        ]))
        #expect(!gate.shouldRetry(error: URLError(.timedOut)))
    }

    @Test("Chunk with no delta (empty choices) does NOT mark yielded")
    func emptyChoicesDoesNotMarkYielded() {
        let gate = DuplicateContentRetryGate()
        gate.markYieldedIfNeeded(makeEmptyChoicesChunk())
        #expect(gate.shouldRetry(error: URLError(.timedOut)))
    }

    // MARK: - Idempotency / stickiness

    @Test("Once yielded, the gate stays latched and ignores further marks")
    func gateIsSticky() {
        let gate = DuplicateContentRetryGate()
        gate.markYieldedIfNeeded(makeChunk(content: "first"))
        // A subsequent empty chunk must not "un-yield".
        gate.markYieldedIfNeeded(makeChunk(content: ""))
        #expect(!gate.shouldRetry(error: URLError(.timedOut)))
    }

    @Test("First non-empty delta wins; later deltas cannot re-arm the gate")
    func firstDeltaWins() {
        let gate = DuplicateContentRetryGate()
        #expect(gate.shouldRetry(error: URLError(.timedOut)))
        gate.markYieldedIfNeeded(makeChunk(reasoning: "hmm"))
        #expect(!gate.shouldRetry(error: URLError(.timedOut)))
        #expect(!gate.shouldRetry(error: LLMServiceError.networkError("again")))
    }

    // MARK: - Concurrency (Sendable)

    @Test("Concurrent marking and checking stays consistent")
    func concurrentAccessIsSafe() async {
        let gate = DuplicateContentRetryGate()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                let chunk = makeChunk(content: index.isMultiple(of: 7) ? "hit" : "")
                group.addTask { gate.markYieldedIfNeeded(chunk) }
            }
        }
        // At least one "hit" was marked → the gate must be latched.
        #expect(!gate.shouldRetry(error: URLError(.timedOut)))
    }
}
