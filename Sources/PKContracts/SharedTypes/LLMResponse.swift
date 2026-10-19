import Foundation

/// One provider response: the assembled content when the caller observes it directly, plus the
/// terminal metadata a provider reports.
///
/// The runtime attaches this value to its generation-completed event and returns it from
/// Timeline-free one-shot generation. `content` is set on one-shot results and left `nil` in the
/// Turn event, where the persisted `Message` owns the response body.
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
    /// Complete tool calls the model requested in this response, in provider order.
    ///
    /// Populated by one-shot paths that fold streamed tool-call deltas. The runtime never
    /// executes these calls; a host that receives them decides whether and how to run each
    /// tool and correlates `.tool` results by ``LLMToolCall/id``.
    public var toolCalls: [LLMToolCall]?
    /// Provider system fingerprint, where the provider reports one.
    public var systemFingerprint: String?
    /// Wall-clock duration of the generation, where the runtime measured it.
    public var duration: TimeInterval?
    /// Throughput derived from `usage` and `duration`, where both are available.
    public var tokensPerSecond: Double?

    public init(
        content: String? = nil,
        id: String? = nil,
        model: String? = nil,
        usage: LLMTokenUsage? = nil,
        finishReason: String? = nil,
        toolCalls: [LLMToolCall]? = nil,
        systemFingerprint: String? = nil,
        duration: TimeInterval? = nil,
        tokensPerSecond: Double? = nil
    ) {
        self.content = content
        self.id = id
        self.model = model
        self.usage = usage
        self.finishReason = finishReason
        self.toolCalls = toolCalls
        self.systemFingerprint = systemFingerprint
        self.duration = duration
        self.tokensPerSecond = tokensPerSecond
    }
}
