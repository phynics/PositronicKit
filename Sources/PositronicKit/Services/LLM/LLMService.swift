import Foundation
import Logging
import Observation
import PKShared
import PKUtilities

/// Set-once box for the one-shot preparation task. It is created before `LLMService` escapes
/// `self` in its initializers, then populated with the actual task once `self` is fully
/// initialized. `set(_:)` traps if called more than once — the box exists to work around the
/// actor-init ordering restriction (a `Task` capturing `self` cannot be assigned directly to a
/// stored property that is itself being initialized), not to be a general-purpose mutable cell.
/// That single-write contract is what makes reading `task` from actor-isolated `await` sites
/// safe without further synchronization; enforcing it here (rather than only documenting it)
/// means a future second write path fails loudly instead of silently racing.
private final class PreparationTaskBox: @unchecked Sendable {
    private(set) var task: Task<Void, Never>?

    init() {}

    func set(_ task: Task<Void, Never>) {
        precondition(self.task == nil, "PreparationTaskBox.set(_:) called more than once")
        self.task = task
    }
}

/// Service for managing LLM interactions with configuration support
public actor LLMService: LanguageModel, HealthCheckable {
    public private(set) var configuration: LLMConfiguration = .openAI

    /// Reports whether the LLM configuration is **valid** (all required fields present for
    /// the active provider). This reflects configuration completeness only — it does **not**
    /// guarantee a primary client is resolved and a send can start. A valid configuration with
    /// no registered client factory yields `isConfigured == true` but ``isReady`` == `false`.
    /// Use ``isReady`` for operational readiness checks before dispatching a request.
    public private(set) var isConfigured: Bool = false

    /// Operational readiness: `true` only when the configuration is valid **and** a primary
    /// client is resolved, guaranteeing a primary send can start. Unlike ``isConfigured``
    /// (configuration validity only), this reflects whether the service can actually dispatch
    /// a request. Preflight callers that need to know a send will not fail with a missing
    /// client should check this instead of ``isConfigured``.
    public var isReady: Bool {
        configuration.isValid && client != nil
    }

    // MARK: - HealthCheckable

    public func getHealthDetails() async -> [String: String]? {
        await preparationTaskBox.task?.value
        var details: [String: String] = [
            "model": configuration.activeProviderConfiguration.modelName,
            "provider": configuration.activeProvider.rawValue,
        ]
        if !configuration.isValid {
            details["readiness"] = "invalid configuration"
        } else if client == nil {
            details["readiness"] = "no client resolved for provider \(configuration.activeProvider.rawValue); no client factory registered"
        } else {
            details["readiness"] = "ready"
        }
        return details
    }

    public func checkHealth() async -> HealthStatus {
        await preparationTaskBox.task?.value
        // Not configured at all → degraded
        guard isConfigured else { return .degraded }

        // Configured but no client instantiated → degraded (configuration may be incomplete)
        guard let client = client else { return .degraded }

        // Proactive connectivity check: if the provider supports model listing,
        // try it; on failure report degraded rather than silently claiming ok.
        do {
            _ = try await client.fetchAvailableModels()
            return .ok
        } catch {
            logger.warning("LLM health check connectivity warning: \(error)")
            return .degraded
        }
    }

    /// Service for generating text embeddings
    public let embeddingService: any EmbeddingServiceProtocol

    private var client: (any LLMClientProtocol)?
    private var utilityClient: (any LLMClientProtocol)?
    private var fastClient: (any LLMClientProtocol)?

    private let storage: any ConfigurationServiceProtocol

/// Optional factory hook that builds provider clients from an `LLMConfiguration`.
    /// Called by `updateClient(with:)` when a configuration change requires new clients.
    /// Hosts compose their factory from each provider's
    /// `makeClientAndRegisterStructuredOutputAdapter(configuration:)`,
    /// keyed on `config.activeProvider`. Falls back to a `(nil, nil, nil)` triple if
    /// none is supplied, matching the behavior for callers that do not need dynamic swapping.
    var clientFactory: (@Sendable (LLMConfiguration) -> (
        main: (any LLMClientProtocol)?, utility: (any LLMClientProtocol)?,
        fast: (any LLMClientProtocol)?
    ))?

    nonisolated let logger: Logger

    /// Holds the one-shot migration/configuration-load task so it can be assigned directly in
    /// `init` without escaping `self` before all stored properties are initialized.
    private nonisolated let preparationTaskBox = PreparationTaskBox()

    /// Internal test hook so regressions can assert the preparation task is assigned synchronously in init.
    nonisolated var hasPreparationTask: Bool {
        preparationTaskBox.task != nil
    }

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
    public init(
        configuration: LLMConfiguration,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        clientFactory: (@Sendable (LLMConfiguration) -> (
            main: (any LLMClientProtocol)?, utility: (any LLMClientProtocol)?,
            fast: (any LLMClientProtocol)?
        ))? = nil
    ) {
        logger = Logger.module(named: "llm")
        self.embeddingService = embeddingService
        storage = InMemoryConfigurationService(config: configuration)
        self.configuration = configuration
        isConfigured = configuration.isValid
        if configuration.isValid {
            let clients = clientFactory?(configuration)
                ?? (main: nil, utility: nil, fast: nil)
            client = clients.main
            utilityClient = clients.utility
            fastClient = clients.fast
        } else {
            client = nil
            utilityClient = nil
            fastClient = nil
        }
        self.clientFactory = clientFactory
    }

    public init(
        storage: any ConfigurationServiceProtocol,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        client: (any LLMClientProtocol)? = nil,
        utilityClient: (any LLMClientProtocol)? = nil,
        fastClient: (any LLMClientProtocol)? = nil,
        clientFactory: (@Sendable (LLMConfiguration) -> (
            main: (any LLMClientProtocol)?, utility: (any LLMClientProtocol)?,
            fast: (any LLMClientProtocol)?
        ))? = nil
    ) {
        logger = Logger.module(named: "llm")
        self.embeddingService = embeddingService
        self.storage = storage
        self.client = client
        self.utilityClient = utilityClient
        self.fastClient = fastClient
        self.clientFactory = clientFactory
        isConfigured = client != nil

        let needsLoad = client == nil
        preparationTaskBox.set(Task { [weak self, needsLoad] in
            guard let self else { return }
            await self.storage.migrateIfNeeded()
            if needsLoad {
                await self.loadConfiguration()
            }
        })
    }

    init(
        storage: any ConfigurationServiceProtocol,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        client: (any LLMClientProtocol)? = nil,
        utilityClient: (any LLMClientProtocol)? = nil,
        fastClient: (any LLMClientProtocol)? = nil,
        clientFactory: (@Sendable (LLMConfiguration) -> (
            main: (any LLMClientProtocol)?, utility: (any LLMClientProtocol)?,
            fast: (any LLMClientProtocol)?
        ))? = nil,
        logger: Logger
    ) {
        self.logger = logger
        self.embeddingService = embeddingService
        self.storage = storage
        self.client = client
        self.utilityClient = utilityClient
        self.fastClient = fastClient
        self.clientFactory = clientFactory
        isConfigured = client != nil

        let needsLoad = client == nil
        preparationTaskBox.set(Task { [weak self, needsLoad] in
            guard let self else { return }
            await self.storage.migrateIfNeeded()
            if needsLoad {
                await self.loadConfiguration()
            }
        })
    }

    // MARK: - Public API

    public func loadConfiguration() async {
        let config = await storage.load()
        configuration = config
        isConfigured = config.isValid

        if config.isValid {
            let providerConfig = config.activeProviderConfiguration
            let modelInfo = "Main: \(providerConfig.modelName), Utility: \(providerConfig.utilityModel), Fast: \(providerConfig.fastModel)"
            logger.info("Loaded configuration. \(modelInfo)")
            updateClient(with: config)
        } else {
            logger.notice("LLM service not yet configured")
        }
    }

    public func restoreFromBackup() async throws {
        await preparationTaskBox.task?.value
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
        await preparationTaskBox.task?.value
        return try await storage.exportConfiguration()
    }

    public func importConfiguration(from data: Data) async throws {
        await preparationTaskBox.task?.value
        logger.info("Importing configuration")
        try await storage.importConfiguration(from: data)
        await loadConfiguration()
    }

    public func updateConfiguration(_ config: LLMConfiguration) async throws {
        await preparationTaskBox.task?.value
        let providerConfig = config.activeProviderConfiguration
        logger.info(
            "Updating configuration to models: \(providerConfig.modelName) / \(providerConfig.utilityModel) / \(providerConfig.fastModel)"
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
        await preparationTaskBox.task?.value
        logger.warning("Clearing configuration")
        await storage.clear()
        configuration = .openAI
        isConfigured = false
        setClients(main: nil, utility: nil, fast: nil)
    }

    public func fetchAvailableModels() async throws -> [String]? {
        await preparationTaskBox.task?.value
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
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel: Bool
    ) async throws -> String {
        await preparationTaskBox.task?.value
        let selectedClient: (any LLMClientProtocol)?
        if useUtilityModel {
            selectedClient = utilityClient ?? client
        } else {
            selectedClient = client
        }

        guard let client = selectedClient else {
            throw configuration.isValid
                ? LLMServiceError.clientNotResolved(provider: configuration.activeProvider.rawValue)
                : LLMServiceError.notConfigured
        }

        // Use provided parameters or default from configuration
        let params = generationParameters ?? configuration.activeProviderConfiguration.generationParameters

        return try await client.sendMessage(
            content,
            responseFormat: responseFormat,
            generationParameters: params
        )
    }
}
