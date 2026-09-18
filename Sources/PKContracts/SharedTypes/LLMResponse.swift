import Foundation

/// One provider response: the assembled content when the caller observes it directly, plus the
/// terminal metadata a provider reports.
///
/// The runtime attaches this value to `TurnEvent.CompletionEvent.generationCompleted` and returns
/// it from Timeline-free one-shot generation. `content` is set on one-shot results and left `nil`
/// in the Turn event, where the persisted `Message` owns the response body.
public struct LLMResponse: Equatable, Sendable, Codable {
    /// The assembled response text, when the response is not already carried by a `Message`.
    public var content: String?
    /// Provider response identifier, where the provider reports one.
    public var id: String?
    /// The model that produced the response.
    public var model: String?
    /// Token accounting for the response.
    public var usage: LLMTokenUsage?
    /// The provider's terminal finish reason.
    public var finishReason: String?
    /// Provider system fingerprint, where the provider reports one.
    public var systemFingerprint: String?
    /// Wall-clock duration of the generation, where the runtime measured it.
    public var duration: TimeInterval?
    /// Throughput derived from `usage` and `duration`, where both are available.
    public var tokensPerSecond: Double?
    /// An encoded diagnostic snapshot, when diagnostic snapshots are enabled.
    public var turnSnapshotData: Data?

    public init(
        content: String? = nil,
        id: String? = nil,
        model: String? = nil,
        usage: LLMTokenUsage? = nil,
        finishReason: String? = nil,
        systemFingerprint: String? = nil,
        duration: TimeInterval? = nil,
        tokensPerSecond: Double? = nil,
        turnSnapshotData: Data? = nil
    ) {
        self.content = content
        self.id = id
        self.model = model
        self.usage = usage
        self.finishReason = finishReason
        self.systemFingerprint = systemFingerprint
        self.duration = duration
        self.tokensPerSecond = tokensPerSecond
        self.turnSnapshotData = turnSnapshotData
    }
}
