import Foundation
import PKShared
import PKUtilities

/// Transport-neutral events synthesized while streaming a `LanguageModelSession` response
/// (PKPOST-003). `LanguageModelSession` is a Swift session API, not a wire protocol, so there
/// is no wire payload to fixture against (unlike the HTTP-family adapters, PKINT-001). Instead,
/// this seam captures exactly what the mapping layer (`FoundationModelsStreamMapper`) needs to
/// synthesize `LLMStreamChunk`s: incremental text, tool-call observations recovered from the
/// session transcript, and a terminal outcome.
///
/// `FoundationModelsSessionProtocol` (below) wraps whatever drives this event sequence — the
/// live session in production, a scripted fixture in tests — so the mapping/bridge/availability
/// layers are fully unit-testable without live Apple Intelligence (PKPOST-003 acceptance: "no
/// live Apple Intelligence needed for tests").
public enum FoundationModelsSessionEvent: Sendable, Equatable {
    /// An incremental slice of the assistant's text response. Snapshots from
    /// `LanguageModelSession.ResponseStream` are cumulative, so the live adapter converts them
    /// to deltas before emitting this case (mirrors `LLMStreamDelta.content` semantics).
    case textDelta(String)

    /// A tool call the framework observed in the transcript, with its already-serialized JSON
    /// arguments. Unlike the HTTP-family adapters, `LanguageModelSession` executes the tool
    /// itself as part of producing the response — this event exists purely for provenance/UI
    /// visibility (PKINT-002 call/result id pairing), not as a "please execute" signal.
    case toolCall(id: String, name: String, argumentsJSON: String)

    /// The tool's result, as recorded in the transcript after the framework invoked it.
    case toolOutput(id: String, name: String, output: String)

    /// The stream reached a terminal state.
    case finished(FinishReason)
}

/// Thin abstraction over a `LanguageModelSession` streaming turn (PKPOST-003 mapping seam).
///
/// The concrete `LanguageModelSession` from `FoundationModels` is `final` with no public
/// initializer disconnected from the real on-device model, so it cannot itself be swapped for a
/// test double. This protocol instead wraps the *outcome* of driving a session — the event
/// sequence a caller cares about — so:
/// - Production code implements it by driving a real `LanguageModelSession` and translating its
///   `ResponseStream` snapshots + transcript into `FoundationModelsSessionEvent`s.
/// - Tests implement it with a scripted fake that yields a fixed event sequence (text-only,
///   multi-tool, guardrail refusal, context-exceeded), with no framework dependency at all.
public protocol FoundationModelsSessionProtocol: Sendable {
    /// Streams one turn's events for the given user prompt. Throws for terminal/non-recoverable
    /// failures (guardrail refusal, context-window overflow, decoding failure, etc.) — these are
    /// mapped to typed errors by the client, never silently swallowed.
    func streamTurn(prompt: String) -> AsyncThrowingStream<FoundationModelsSessionEvent, Error>
}
