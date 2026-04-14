import Foundation

/// Parameters for LLM generation
public struct GenerationParameters: Codable, Sendable, Equatable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var topP: Double?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
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
