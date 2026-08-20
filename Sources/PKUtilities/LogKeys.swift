import PKContracts
import Foundation

/// Canonical PositronicKit loop-metadata vocabulary for `Logger.Metadata` keys.
///
/// All structured-log sites across the turn loop — prompt assembly, LLM stream
/// lifecycle, loop continuation decisions, and tool routing — MUST use these keys
/// (via `LogKeys.<key>`) rather than ad-hoc string literals or synonyms such as the
/// legacy vocabulary. Keeping the vocabulary canonical lets downstream consumers
/// correlate log lines by `threadID` / `turnID` / `requestID` / `modelRoundIndex` without regex, and keeps
/// per-tool / per-provider attribution consistent across stages.
///
/// The set mirrors the existing logger scheme (`"turn-engine"` / `"tool-router"` /
/// `"llm"` categories) and the metadata already emitted by `ToolCallExtractionStage`
/// (PKLOG-001/002/003). New loop components adopt these keys rather than introducing
/// synonyms.
package enum LogKeys {
    /// Raw thread UUID string (not hashed) — correlates end-to-end with Yakamoz logs
    /// (YAK-40), which log the raw `threadId`. A UUID is an id, not a payload.
    package static let threadID = "threadID"

    /// Turn UUID — identifies one user turn independently from its request/idempotency UUID.
    package static let turnID = "turnID"

    /// Request/idempotency UUID — disambiguates retries and rounds within a thread.
    package static let requestID = "requestID"

    /// Model round index within the current turn (the `modelRoundIndex` on `TurnContext`).
    package static let modelRoundIndex = "modelRoundIndex"

    /// Display name of the tool being routed/executed.
    package static let toolName = "toolName"

    /// Active LLM provider raw value (e.g. `"OpenAI"`, `"Ollama"`).
    package static let provider = "provider"

    /// Pipeline stage emitting the log (e.g. `"llm-streaming"`, `"tool-call-extraction"`).
    package static let stage = "stage"

    /// Stable `PKError` code (numeric) for a logged failure, so a failure's identity is
    /// machine-readable in logs without re-casting the error.
    package static let errorCode = "errorCode"

    /// Stable domain for a logged error.
    package static let errorDomain = "errorDomain"

    /// Correlation identifier for one request or tool attempt.
    package static let correlationID = "correlationID"
}
