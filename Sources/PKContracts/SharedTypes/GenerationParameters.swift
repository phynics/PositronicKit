import Foundation

/// Sampling and length parameters for a single LLM generation request.
///
/// Every field is optional. Provider adapters (e.g. `OpenAIClient`, `AnthropicClient`,
/// `OllamaClient`) forward a `nil` field as `nil` in the outgoing request rather than
/// substituting a value, so the underlying provider/model applies its own default for
/// any field left unset here.
public struct GenerationParameters: Codable, Sendable, Equatable {
    /// Sampling temperature; higher values increase randomness. `nil` leaves the
    /// provider/model default in effect.
    public var temperature: Double?

    /// Maximum number of tokens to generate in the response. `nil` leaves the
    /// provider/model default (or its own max) in effect.
    public var maxTokens: Int?

    /// Nucleus-sampling probability mass. `nil` leaves the provider/model default in effect.
    public var topP: Double?

    /// Penalty applied to tokens based on their existing frequency in the generated text,
    /// discouraging repetition. `nil` leaves the provider/model default in effect.
    public var frequencyPenalty: Double?

    /// Penalty applied to tokens that have already appeared at all, encouraging new topics.
    /// `nil` leaves the provider/model default in effect.
    public var presencePenalty: Double?

    /// Seed for deterministic sampling, where the provider supports it. `nil` leaves
    /// sampling non-deterministic (or provider-default).
    public var seed: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        seed: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
    }
}
