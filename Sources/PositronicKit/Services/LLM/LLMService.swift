import Dependencies
import ErrorKit
import Foundation
import Logging
import PKShared
import Observation
import OpenAI

/// Protocol for LLM Clients
public protocol LLMClientProtocol: Sendable {
    func chatStream(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]?,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?,
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<ChatStreamResult, Error>

    func sendMessage(
        _ content: String,
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?
    ) async throws -> String

    /// Optional: Fetch available models from the service. Returns nil if not supported.
    func fetchAvailableModels() async throws -> [String]?
}

public extension LLMClientProtocol {
    func fetchAvailableModels() async throws -> [String]? {
        return nil
    }
}

/// Conform OpenAIClient (Retroactive - now in same module)
extension OpenAIClient: LLMClientProtocol {}

/// Conform OllamaClient
extension OllamaClient: LLMClientProtocol {}

/// Conform OpenRouterClient
extension OpenRouterClient: LLMClientProtocol {}

/// Service for managing LLM interactions with configuration support
public actor LLMService: LLMServiceProtocol, HealthCheckable {
    public private(set) var configuration: LLMConfiguration = .openAI
    public private(set) var isConfigured: Bool = false

    // MARK: - HealthCheckable

    public func getHealthStatus() async -> HealthStatus {
        await preparationTask?.value
        return isConfigured ? .ok : .degraded
    }

    public func getHealthDetails() async -> [String: String]? {
        await preparationTask?.value
        return [
            "model": configuration.modelName,
            "provider": configuration.endpoint.contains("openai")
                ? "openai"
                : (configuration.endpoint.contains("openrouter") ? "openrouter" : "custom"),
        ]
    }

    public func checkHealth() async -> HealthStatus {
        await preparationTask?.value
        // Basic check: is configured
        guard isConfigured else { return .degraded }

        // Optional: Proactive check by trying to list models (if supported)
        do {
            if let client = client {
                _ = try await client.fetchAvailableModels()
                return .ok
            }
            return .degraded
        } catch {
            logger.warning("LLM health check connectivity warning: \(error)")
            // We return ok if configured even if network check fails,
            // but we could return degraded if we want to be strict.
            return .ok
        }
    }

    /// Service for generating text embeddings
    @Dependency(\.embeddingService) public var embeddingService

    private var client: (any LLMClientProtocol)?
    private var utilityClient: (any LLMClientProtocol)?
    private var fastClient: (any LLMClientProtocol)?

    private let storage: any ConfigurationServiceProtocol

    let logger = Logger.module(named: "llm")

    private var preparationTask: Task<Void, Never>?

    // MARK: - Client Accessors

    public func getClient() -> (any LLMClientProtocol)? {
        return client
    }

    public func getUtilityClient() -> (any LLMClientProtocol)? {
        return utilityClient
    }

    public func getFastClient() -> (any LLMClientProtocol)? {
        return fastClient
    }

    public func setClients(
        main: (any LLMClientProtocol)?, utility: (any LLMClientProtocol)?,
        fast: (any LLMClientProtocol)?
    ) {
        client = main
        utilityClient = utility
        fastClient = fast
    }

    // MARK: - Initialization

    /// Initializes with a direct configuration using in-memory storage.
    public init(configuration: LLMConfiguration) {
        self.storage = InMemoryConfigurationService(config: configuration)
        self.configuration = configuration
        self.isConfigured = configuration.isValid
        if configuration.isValid {
            let clients = Self.makeClients(with: configuration)
            self.client = clients.main
            self.utilityClient = clients.utility
            self.fastClient = clients.fast
        } else {
            self.client = nil
            self.utilityClient = nil
            self.fastClient = nil
        }
        self.preparationTask = nil
    }

    public init(
        storage: any ConfigurationServiceProtocol,
        client: (any LLMClientProtocol)? = nil,
        utilityClient: (any LLMClientProtocol)? = nil,
        fastClient: (any LLMClientProtocol)? = nil
    ) {
        self.storage = storage
        self.client = client
        self.utilityClient = utilityClient
        self.fastClient = fastClient
        isConfigured = client != nil

        let needsLoad = client == nil

        self.preparationTask = nil
        let t = Task { [needsLoad] in
            await storage.migrateIfNeeded()
            if needsLoad {
                await self.loadConfiguration()
            }
        }
        Task { await self.setPreparationTask(t) }
    }

    // MARK: - Public API

    private func setPreparationTask(_ task: Task<Void, Never>) {
        self.preparationTask = task
    }

    public func loadConfiguration() async {
        let config = await storage.load()
        configuration = config
        isConfigured = config.isValid

        if config.isValid {
            let modelInfo = "Main: \(config.modelName), Utility: \(config.utilityModel), Fast: \(config.fastModel)"
            logger.info("Loaded configuration. \(modelInfo)")
            updateClient(with: config)
        } else {
            logger.notice("LLM service not yet configured")
        }
    }

    public func restoreFromBackup() async throws {
        await preparationTask?.value
        if let restored = try await storage.restoreFromBackup() {
            logger.info("Restored configuration from backup")
            configuration = restored
            isConfigured = restored.isValid

            if restored.isValid {
                updateClient(with: restored)
            }
        }
    }

    public func exportConfiguration() async throws -> Data {
        await preparationTask?.value
        return try await storage.exportConfiguration()
    }

    public func importConfiguration(from data: Data) async throws {
        await preparationTask?.value
        logger.info("Importing configuration")
        try await storage.importConfiguration(from: data)
        await loadConfiguration()
    }

    public func updateConfiguration(_ config: LLMConfiguration) async throws {
        await preparationTask?.value
        logger.info(
            "Updating configuration to models: \(config.modelName) / \(config.utilityModel) / \(config.fastModel)"
        )
        try await storage.save(config)
        configuration = config
        isConfigured = config.isValid

        if config.isValid {
            updateClient(with: config)
        } else {
            setClients(main: nil, utility: nil, fast: nil)
        }
    }

    public func clearConfiguration() async {
        await preparationTask?.value
        logger.warning("Clearing configuration")
        await storage.clear()
        configuration = .openAI
        isConfigured = false
        setClients(main: nil, utility: nil, fast: nil)
    }

    public func fetchAvailableModels() async throws -> [String]? {
        await preparationTask?.value
        guard let client = client else {
            return nil
        }
        return try await client.fetchAvailableModels()
    }

    public func sendMessage(_ content: String) async throws -> String {
        try await sendMessage(content, responseFormat: nil, generationParameters: nil, useUtilityModel: false)
    }

    public func sendMessage(
        _ content: String,
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel: Bool
    ) async throws -> String {
        await preparationTask?.value
        let selectedClient: (any LLMClientProtocol)?
        if useUtilityModel {
            selectedClient = utilityClient ?? client
        } else {
            selectedClient = client
        }

        guard let client = selectedClient else {
            throw LLMServiceError.notConfigured
        }

        // Use provided parameters or default from configuration
        let params = generationParameters ?? configuration.generationParameters

        return try await client.sendMessage(
            content,
            responseFormat: responseFormat,
            generationParameters: params
        )
    }
}

// MARK: - Error Types

public enum LLMServiceError: PKError, Equatable {
    case notConfigured
    case invalidConfiguration
    case networkError(String)

    public var errorDomain: String { PKErrorDomain.llm }

    public var errorCode: Int {
        switch self {
        case .notConfigured: return 1001
        case .invalidConfiguration: return 1002
        case .networkError: return 1003
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .notConfigured:
            return "LLM service is not configured. Please set up your API endpoint and key."
        case .invalidConfiguration:
            return "Invalid LLM configuration. Please check your settings."
        case let .networkError(message):
            return "Network error: \(message)"
        }
    }
}
