import PKContracts

/// The terminal result of a one-shot generation, without timeline state.
public struct OneShotResult: Sendable, Equatable {
    public let content: String
    public let id: String?
    public let model: String?
    public let usage: LLMTokenUsage?
    public let finishReason: String?

    public init(
        content: String,
        id: String? = nil,
        model: String? = nil,
        usage: LLMTokenUsage? = nil,
        finishReason: String? = nil
    ) {
        self.content = content
        self.id = id
        self.model = model
        self.usage = usage
        self.finishReason = finishReason
    }
}
