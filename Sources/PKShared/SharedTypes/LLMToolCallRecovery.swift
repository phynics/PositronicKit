import Foundation

/// Tracks a streaming turn's tool-call state so the runtime can detect and recover from
/// providers that report `finishReason == toolCalls` without ever streaming the tool-call
/// deltas themselves (a known provider quirk), and decide whether a mid-stream error is
/// safe to retry.
public struct LLMToolCallRecoveryState: Sendable, Equatable {
    /// Whether any content (text or streamed tool-call deltas) has been yielded to the caller yet.
    public var hasYielded = false
    /// Whether at least one streamed tool-call delta was actually observed.
    public var sawStreamedToolCalls = false
    /// Whether the stream finished with a tool-calls finish reason.
    public var finishedWithToolCalls = false

    public init() {}

    /// Updates the recovery state after observing a chunk's yield/tool-call signals.
    public mutating func observe(
        yieldedContent: Bool,
        streamedToolCalls: Bool,
        finishedWithToolCalls: Bool
    ) {
        if yieldedContent {
            hasYielded = true
        }
        if streamedToolCalls {
            hasYielded = true
            sawStreamedToolCalls = true
        }
        if finishedWithToolCalls {
            self.finishedWithToolCalls = true
        }
    }

    /// `true` when the stream claimed tool calls happened but never streamed their deltas —
    /// signals the runtime should attempt to recover the tool calls another way (e.g. a
    /// non-streamed follow-up request).
    public var shouldRecoverToolCalls: Bool {
        finishedWithToolCalls && !sawStreamedToolCalls
    }

    /// `true` when nothing has been yielded yet, meaning a mid-stream error is safe to
    /// retry without risking duplicated partial output.
    public var shouldRetryAfterError: Bool {
        !hasYielded
    }
}
