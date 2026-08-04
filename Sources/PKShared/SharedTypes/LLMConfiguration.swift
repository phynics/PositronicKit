import ErrorKit
import Foundation

/// Configuration for LLM service
public struct LLMConfiguration: Codable, Sendable, Equatable {
    public var activeProvider: LLMProvider
    public var providers: [LLMProvider: ProviderConfiguration]

    public var memoryContextLimit: Int
    public var documentContextLimit: Int
    public var version: Int

    // MARK: - Active Provider Access

    /// The `ProviderConfiguration` for `activeProvider`, falling back to that provider's
    /// defaults if `providers` has no entry for it. This is the canonical way to read the
    /// currently active provider's settings — construct/mutate `providers[activeProvider]`
    /// directly to write.
    public var activeProviderConfiguration: ProviderConfiguration {
        providers[activeProvider] ?? .makeDefault(for: activeProvider)
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
            initialProviders[provider] = ProviderConfiguration.makeDefault(for: provider)
        }

        // Merge provided overrides
        if let providers = providers {
            for (key, value) in providers {
                initialProviders[key] = value
            }
        }
        self.providers = initialProviders
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
