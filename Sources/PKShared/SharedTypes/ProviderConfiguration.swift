import Foundation

public struct ProviderConfiguration: Codable, Sendable, Equatable {
    public var endpoint: String
    public var apiKey: String
    public var modelName: String
    public var utilityModel: String
    public var fastModel: String
    public var toolFormat: ToolCallFormat
    public var timeoutInterval: TimeInterval
    public var maxRetries: Int

    /// The model's full context-window size in tokens. Prompt compression budgets are derived
    /// from this value (minus the response output reserve and provider overhead), **not** from
    /// `GenerationParameters.maxTokens` (which is the response output limit). Override this to
    /// steer budgeting for a specific model; the per-provider default reflects the configured
    /// `modelName`'s typical capacity (see ``defaultFor(_:)``).
    public var contextWindowTokens: Int

    public var temperature: Double?
    public var maxTokens: Int?
    public var topP: Double?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var seed: Int?

    /// Attribution URL sent as `HTTP-Referer` by providers that support attribution headers
    /// (currently OpenRouter). `nil` omits the header entirely rather than sending it empty.
    public var applicationURL: String?
    /// Attribution title sent as `X-Title` by providers that support attribution headers
    /// (currently OpenRouter). `nil` omits the header entirely rather than sending it empty.
    public var applicationTitle: String?

    public var generationParameters: GenerationParameters {
        GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            topP: topP,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            seed: seed
        )
    }

    public init(
        endpoint: String,
        apiKey: String,
        modelName: String,
        utilityModel: String,
        fastModel: String,
        toolFormat: ToolCallFormat,
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        contextWindowTokens: Int = 8_192,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        seed: Int? = nil,
        applicationURL: String? = nil,
        applicationTitle: String? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.modelName = modelName
        self.utilityModel = utilityModel
        self.fastModel = fastModel
        self.toolFormat = toolFormat
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
        self.contextWindowTokens = contextWindowTokens
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
        self.applicationURL = applicationURL
        self.applicationTitle = applicationTitle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        modelName = try container.decode(String.self, forKey: .modelName)
        utilityModel = try container.decode(String.self, forKey: .utilityModel)
        fastModel = try container.decode(String.self, forKey: .fastModel)
        toolFormat = try container.decodeIfPresent(ToolCallFormat.self, forKey: .toolFormat) ?? .openAI
        timeoutInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutInterval) ?? 60.0
        maxRetries = try container.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 3
        contextWindowTokens = try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? 8_192

        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        frequencyPenalty = try container.decodeIfPresent(Double.self, forKey: .frequencyPenalty)
        presencePenalty = try container.decodeIfPresent(Double.self, forKey: .presencePenalty)
        seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        applicationURL = try container.decodeIfPresent(String.self, forKey: .applicationURL)
        applicationTitle = try container.decodeIfPresent(String.self, forKey: .applicationTitle)
    }

    public static func defaultFor(_ provider: LLMProvider) -> ProviderConfiguration {
        switch provider {
        case .openAI:
            return ProviderConfiguration(
                endpoint: "https://api.openai.com",
                apiKey: "",
                modelName: "gpt-4o",
                utilityModel: "gpt-4o-mini",
                fastModel: "gpt-4o-mini",
                toolFormat: .openAI,
                timeoutInterval: 60.0,
                maxRetries: 3,
                contextWindowTokens: 128_000
            )
        case .openRouter:
            return ProviderConfiguration(
                endpoint: "https://openrouter.ai/api",
                apiKey: "",
                modelName: "openai/gpt-4o",
                utilityModel: "openai/gpt-4o-mini",
                fastModel: "openai/gpt-4o-mini",
                toolFormat: .openAI,
                timeoutInterval: 60.0,
                maxRetries: 3,
                contextWindowTokens: 128_000
            )
        case .ollama:
            return ProviderConfiguration(
                endpoint: "http://localhost:11434/api",
                apiKey: "",
                modelName: "llama3",
                utilityModel: "llama3",
                fastModel: "llama3",
                toolFormat: .openAI,
                timeoutInterval: 120.0, // Local models can be slower
                maxRetries: 3,
                contextWindowTokens: 8_192
            )
        case .anthropic:
            return ProviderConfiguration(
                endpoint: "https://api.anthropic.com",
                apiKey: "",
                modelName: "claude-sonnet-4-5",
                utilityModel: "claude-haiku-4-5",
                fastModel: "claude-haiku-4-5",
                toolFormat: .openAI,
                timeoutInterval: 60.0,
                maxRetries: 3,
                contextWindowTokens: 200_000
            )
        case .openAICompatible:
            return ProviderConfiguration(
                endpoint: "http://localhost:1234/v1",
                apiKey: "",
                modelName: "model",
                utilityModel: "model",
                fastModel: "model",
                toolFormat: .openAI,
                timeoutInterval: 60.0,
                maxRetries: 3,
                contextWindowTokens: 8_192
            )
        }
    }
}
