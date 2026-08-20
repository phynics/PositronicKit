import PKContracts
import Foundation

/// Canonical PositronicKit loop-metadata vocabulary for `Logger.Metadata` keys.
///
/// All structured-log sites across the chat turn loop — prompt assembly, LLM stream
/// lifecycle, loop continuation decisions, and tool routing — MUST use these keys
/// (via `LogKeys.<key>`) rather than ad-hoc string literals or synonyms such as the
/// legacy `conversationID`. Keeping the vocabulary canonical lets downstream consumers
/// correlate log lines by `timelineID` / `sendID` / `turnIndex` without regex, and keeps
/// per-tool / per-provider attribution consistent across stages.
///
/// The set mirrors the existing logger scheme (`"chat-engine"` / `"tool-router"` /
/// `"llm"` categories) and the metadata already emitted by `ToolCallExtractionStage`
/// (PKLOG-001/002/003). New loop components adopt these keys rather than introducing
/// synonyms.
public enum LogKeys {
    /// Raw timeline UUID string (not hashed) — correlates end-to-end with Yakamoz logs
    /// (YAK-40), which log the raw `timelineId`. A UUID is an id, not a payload.
    public static let timelineID = "timelineID"

    /// Per-send UUID — disambiguates rounds within a timeline across multiple user sends
    /// (a `turnIndex` of 0 collides across sends without this).
    public static let sendID = "sendID"

    /// Turn index within the current send (the `turnCount` on `ChatTurnContext`).
    public static let turnIndex = "turnIndex"

    /// Display name of the tool being routed/executed.
    public static let toolName = "toolName"

    /// Active LLM provider raw value (e.g. `"OpenAI"`, `"Ollama"`).
    public static let provider = "provider"

    /// Pipeline stage emitting the log (e.g. `"llm-streaming"`, `"tool-call-extraction"`).
    public static let stage = "stage"

    /// Stable `PKError` code (numeric) for a logged failure, so a failure's identity is
    /// machine-readable in logs without re-casting the error.
    public static let errorCode = "errorCode"

    /// Stable domain for a logged error.
    public static let errorDomain = "errorDomain"

    /// Correlation identifier for one request or tool attempt.
    public static let correlationID = "correlationID"
}
