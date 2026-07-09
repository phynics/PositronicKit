import ErrorKit
import Foundation

/// Configuration for LLM service
public struct LLMConfiguration: Codable, Sendable, Equatable {
    public var activeProvider: LLMProvider
    public var providers: [LLMProvider: ProviderConfiguration]

    public var memoryContextLimit: Int
    public var documentContextLimit: Int
    public var version: Int

    // MARK: - Computed Properties (Backwards Compatibility)

    //
    // Every property below is a write-through proxy onto
    // `providers[activeProvider]`, not independent state: reading returns that
    // provider's field (or a fallback default if `activeProvider` has no entry
    // in `providers`), and writing mutates that same provider's `ProviderConfiguration`
    // in place. Switching `activeProvider` changes what these properties report/mutate
    // without saving or restoring any values — there is no independent "top-level"
    // config underneath. This exists for source-compatibility with call sites written
    // before `providers`/`activeProvider` was introduced; prefer reading/writing
    // `providers[activeProvider]` directly in new code so the write-through relationship
    // is visible at the call site.

    public var endpoint: String {
        get { providers[activeProvider]?.endpoint ?? "" }
        set { providers[activeProvider]?.endpoint = newValue }
    }

    public var apiKey: String {
        get { providers[activeProvider]?.apiKey ?? "" }
        set { providers[activeProvider]?.apiKey = newValue }
    }

    public var modelName: String {
        get { providers[activeProvider]?.modelName ?? "" }
        set { providers[activeProvider]?.modelName = newValue }
    }

    public var utilityModel: String {
        get { providers[activeProvider]?.utilityModel ?? "" }
        set { providers[activeProvider]?.utilityModel = newValue }
    }

    public var fastModel: String {
        get { providers[activeProvider]?.fastModel ?? "" }
        set { providers[activeProvider]?.fastModel = newValue }
    }

    public var toolFormat: ToolCallFormat {
        get { providers[activeProvider]?.toolFormat ?? .openAI }
        set { providers[activeProvider]?.toolFormat = newValue }
    }

    public var timeoutInterval: TimeInterval {
        get { providers[activeProvider]?.timeoutInterval ?? 60.0 }
        set { providers[activeProvider]?.timeoutInterval = newValue }
    }

    public var maxRetries: Int {
        get { providers[activeProvider]?.maxRetries ?? 3 }
        set { providers[activeProvider]?.maxRetries = newValue }
    }

    public var temperature: Double? {
        get { providers[activeProvider]?.temperature }
        set { providers[activeProvider]?.temperature = newValue }
    }

    public var maxTokens: Int? {
        get { providers[activeProvider]?.maxTokens }
        set { providers[activeProvider]?.maxTokens = newValue }
    }

    public var topP: Double? {
        get { providers[activeProvider]?.topP }
        set { providers[activeProvider]?.topP = newValue }
    }

    public var frequencyPenalty: Double? {
        get { providers[activeProvider]?.frequencyPenalty }
        set { providers[activeProvider]?.frequencyPenalty = newValue }
    }

    public var presencePenalty: Double? {
        get { providers[activeProvider]?.presencePenalty }
        set { providers[activeProvider]?.presencePenalty = newValue }
    }

    public var seed: Int? {
        get { providers[activeProvider]?.seed }
        set { providers[activeProvider]?.seed = newValue }
    }

    /// Attribution URL sent as `HTTP-Referer` by providers that support attribution headers
    /// (currently OpenRouter). `nil` omits the header entirely rather than sending it empty.
    public var applicationURL: String? {
        get { providers[activeProvider]?.applicationURL }
        set { providers[activeProvider]?.applicationURL = newValue }
    }

    /// Attribution title sent as `X-Title` by providers that support attribution headers
    /// (currently OpenRouter). `nil` omits the header entirely rather than sending it empty.
    public var applicationTitle: String? {
        get { providers[activeProvider]?.applicationTitle }
        set { providers[activeProvider]?.applicationTitle = newValue }
    }

    public var generationParameters: GenerationParameters {
        providers[activeProvider]?.generationParameters ?? GenerationParameters()
    }

    public var provider: LLMProvider {
        get { activeProvider }
        set { activeProvider = newValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeProvider = try container.decode(LLMProvider.self, forKey: .activeProvider)
        providers = try container.decode([LLMProvider: ProviderConfiguration].self, forKey: .providers)

        memoryContextLimit = try container.decodeIfPresent(Int.self, forKey: .memoryContextLimit) ?? 5
        documentContextLimit = try container.decodeIfPresent(Int.self, forKey: .documentContextLimit) ?? 5
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 5
    }

    public init(
        activeProvider: LLMProvider = .openAI,
        providers: [LLMProvider: ProviderConfiguration]? = nil,
        memoryContextLimit: Int = 5,
        documentContextLimit: Int = 5,
        version: Int = 5
    ) {
        self.activeProvider = activeProvider
        self.memoryContextLimit = memoryContextLimit
        self.documentContextLimit = documentContextLimit
        self.version = version

        // Initialize providers with defaults if not provided
        var initialProviders: [LLMProvider: ProviderConfiguration] = [:]
        for provider in LLMProvider.allCases {
            initialProviders[provider] = ProviderConfiguration.defaultFor(provider)
        }

        // Merge provided overrides
        if let providers = providers {
            for (key, value) in providers {
                initialProviders[key] = value
            }
        }
        self.providers = initialProviders
    }

    /// Convenience init for legacy support (flat structure)
    /// This maps the flat arguments to the ACTIVE provider's config
    public init(
        endpoint: String = "https://api.openai.com",
        modelName: String = "gpt-4o",
        utilityModel: String = "gpt-4o-mini",
        fastModel: String = "gpt-4o-mini",
        apiKey: String = "",
        version: Int = 5,
        provider: LLMProvider = .openAI,
        toolFormat: ToolCallFormat = .openAI,
        memoryContextLimit: Int = 5,
        documentContextLimit: Int = 5,
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        seed: Int? = nil,
        applicationURL: String? = nil,
        applicationTitle: String? = nil
    ) {
        activeProvider = provider
        self.memoryContextLimit = memoryContextLimit
        self.documentContextLimit = documentContextLimit
        self.version = version

        // Initialize all defaults
        var initialProviders: [LLMProvider: ProviderConfiguration] = [:]
        for defaultProvider in LLMProvider.allCases {
            initialProviders[defaultProvider] = ProviderConfiguration.defaultFor(defaultProvider)
        }

        // Override the active one with passed values
        initialProviders[provider] = ProviderConfiguration(
            endpoint: endpoint,
            apiKey: apiKey,
            modelName: modelName,
            utilityModel: utilityModel,
            fastModel: fastModel,
            toolFormat: toolFormat,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            temperature: temperature,
            maxTokens: maxTokens,
            topP: topP,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            seed: seed,
            applicationURL: applicationURL,
            applicationTitle: applicationTitle
        )

        providers = initialProviders
    }

    /// Default OpenAI configuration
    public static var openAI: LLMConfiguration {
        LLMConfiguration(activeProvider: .openAI)
    }

    /// Default OpenRouter configuration
    public static var openRouter: LLMConfiguration {
        LLMConfiguration(activeProvider: .openRouter)
    }

    public static var `default`: LLMConfiguration {
        LLMConfiguration()
    }

    /// Validate configuration
    public var isValid: Bool {
        (try? validate()) != nil
    }

    /// Validates the LLM configuration and throws descriptive errors on failure.
    public func validate() throws {
        guard let config = providers[activeProvider] else {
            throw ConfigurationError.invalidConfiguration(
                reason: "Active provider '\(activeProvider.rawValue)' has no configuration."
            )
        }

        if config.modelName.isEmpty {
            throw ConfigurationError.invalidConfiguration(
                reason: "Primary model name is empty for \(activeProvider.rawValue)."
            )
        }

        if activeProvider != .ollama, config.apiKey.isEmpty {
            throw ConfigurationError.missingAPIKey(activeProvider)
        }

        if !isValidEndpoint(config.endpoint) {
            throw ConfigurationError.invalidEndpoint(config.endpoint)
        }
    }

    /// Validate endpoint URL format
    private func isValidEndpoint(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }
}

// MARK: - Errors

public enum ConfigurationError: Throwable {
    case invalidConfiguration(reason: String)
    case missingAPIKey(LLMProvider)
    case invalidEndpoint(String)
    case noBackupFound
    case importFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reason):
            return "Invalid configuration: \(reason)"
        case let .missingAPIKey(provider):
            return "Missing API key for provider: \(provider.rawValue)"
        case let .invalidEndpoint(endpoint):
            return "Invalid endpoint URL: \(endpoint)"
        case .noBackupFound:
            return "No backup configuration found"
        case .importFailed:
            return "Failed to import configuration: Invalid format"
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .invalidConfiguration(reason):
            return "Your configuration is invalid: \(reason)"
        case let .missingAPIKey(provider):
            return "Your API key for \(provider.rawValue) is missing. Please set it in your configuration."
        case .invalidEndpoint:
            return "The LLM endpoint URL is invalid."
        case .noBackupFound:
            return "No backup configuration found."
        case .importFailed:
            return "The imported configuration is in an invalid format."
        }
    }
}
