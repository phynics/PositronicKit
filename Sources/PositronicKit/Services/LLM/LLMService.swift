import Foundation
import Logging
import PKContracts
import PKUtilities

/// Service for managing LLM interactions with configuration support.
///
/// Owns exactly one actor-isolated runtime snapshot (configuration + client set).
/// Every configuration transition replaces the snapshot wholesale through the
/// internal `apply(_:)`, and every dispatch path resolves clients through the single
/// `resolve(tier:)` operation, so the service never runs with stale clients,
/// conflicting readiness, or duplicated tier fallback rules.
public actor LLMService: LLMStreamClient, LLMConfigStore, HealthCheckable {
    /// The current configuration. Read-only projection of the runtime snapshot.
    public var configuration: LLMConfiguration {
        snapshot.configuration
    }

    /// Reports whether the LLM configuration is **valid** (all required fields present for
    /// the active provider). This reflects configuration completeness only — it does **not**
    /// guarantee a primary client is resolved and a send can start. A valid configuration with
    /// no registered client resolver yields `isConfigured == true` but ``isReady`` == `false`.
    /// Use ``isReady`` for operational readiness checks before dispatching a request.
    public var isConfigured: Bool {
        snapshot.configuration.isValid
    }

    /// Operational readiness: `true` only when the configuration is valid **and** a primary
    /// client is resolved, guaranteeing a primary send can start. Unlike ``isConfigured``
    /// (configuration validity only), this reflects whether the service can actually dispatch
    /// a request. Preflight callers that need to know a send will not fail with a missing
    /// client should check this instead of ``isConfigured``.
    public var isReady: Bool {
        snapshot.readiness == .ready
    }

    // MARK: - HealthCheckable

    public func getHealthDetails() async -> [String: String]? {
        await prepareIfNeeded()
        var details: [String: String] = [
            "model": snapshot.configuration.activeProviderConfiguration.modelName,
            "provider": snapshot.configuration.activeProvider.rawValue,
        ]
        switch snapshot.readiness {
        case .invalidConfiguration:
            details["readiness"] = "invalid configuration"
        case let .clientUnavailable(provider):
            details["readiness"] = "no client resolved for provider \(provider.rawValue); no client factory supplied"
        case .ready:
            details["readiness"] = "ready"
        }
        return details
    }

    public func checkHealth() async -> HealthStatus {
        await prepareIfNeeded()
        switch snapshot.readiness {
        case .invalidConfiguration, .clientUnavailable:
            return .degraded
        case .ready:
            guard let client = snapshot.clients.primary else { return .degraded }
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
    }

    // MARK: - Runtime State

    private var snapshot: LLMRuntimeSnapshot
    private let configurationRepository: LLMConfigurationRepository
    private let clientResolver: any LLMClientResolving

    nonisolated let logger: Logger

    private enum PreparationState {
        case pending
        case loading(Task<LLMConfiguration, Never>)
        case ready
    }

    private var preparationState: PreparationState

    /// Applies a configuration through the resolver, clearing clients when it is invalid.
    ///
    /// This is the only path that transitions runtime state; no load, import, restore,
    /// update, or clear operation assigns configuration and clients separately.
    private func apply(_ configuration: LLMConfiguration) {
        let clients = configuration.isValid
            ? clientResolver.clients(for: configuration)
            : .empty
        snapshot = LLMRuntimeSnapshot(configuration: configuration, clients: clients)
    }

    private func apply(_ configuration: LLMConfiguration, clients: LLMClientSet) {
        snapshot = LLMRuntimeSnapshot(configuration: configuration, clients: clients)
    }

    /// Coalesces the one-shot migration/load task inside the actor, capturing only the
    /// repository — never `self`.
    func prepareIfNeeded() async {
        let task: Task<LLMConfiguration, Never> // swiftlint:disable:this concurrency_stored_task -- actor method-local coalesced task (see docs/Concurrency/exception-manifest.md)

        switch preparationState {
        case .ready:
            return
        case let .loading(existing):
            task = existing
        case .pending:
            let repository = configurationRepository
            task = Task {
                await repository.migrateAndLoad()
            }
            preparationState = .loading(task)
        }

        let configuration = await task.value

        // A second re-entrant caller may already have applied it.
        guard case .ready = preparationState else {
            apply(configuration)
            preparationState = .ready
            return
        }
    }

    /// Resolves the client and generation defaults for a model tier.
    ///
    /// The single implementation of tier selection, fallback, and missing-client error
    /// mapping. Used by both stream overloads, structured-output adapters, model listing,
    /// and health checks.
    func resolve(tier: ModelTier) throws -> ResolvedLLMClient {
        let snapshot = self.snapshot
        guard snapshot.configuration.isValid else {
            throw LLMServiceError.notConfigured
        }
        guard let client = snapshot.clients.client(for: tier) else {
            throw LLMServiceError.clientNotResolved(provider: snapshot.configuration.activeProvider.rawValue)
        }
        return ResolvedLLMClient(
            client: client,
            generationParameters: snapshot.configuration.activeProviderConfiguration.generationParameters
        )
    }

    public func structuredOutputAdapter(
        for modelTier: ModelTier
    ) async -> any StructuredOutputAdapter {
        await prepareIfNeeded()
        guard let client = snapshot.clients.client(for: modelTier) else {
            return DefaultStructuredOutputAdapter()
        }
        return await client.structuredOutputAdapter
    }

    // MARK: - Initialization

    /// Designated: explicit configuration plus the client set to dispatch through.
    ///
    /// The service is immediately ready — no storage load is performed. Clients are kept
    /// regardless of later `updateConfiguration(_:)` calls; hosts that need clients to track
    /// configuration changes should use ``init(storage:clientResolver:logger:)`` instead.
    public init(
        configuration: LLMConfiguration,
        clients: LLMClientSet,
        logger: Logger = Logger.module(named: "llm")
    ) {
        self.init(
            configuration: configuration,
            clientResolver: FixedClientsResolver(clients: clients),
            logger: logger
        )
    }

    /// Designated: load the configuration from storage, resolving clients through a resolver.
    ///
    /// The first public operation waits for migration + load; the resolved configuration
    /// (not the initializer arguments) becomes authoritative.
    public init(
        storage: any ConfigurationServiceProtocol,
        clientResolver: any LLMClientResolving,
        logger: Logger = Logger.module(named: "llm")
    ) {
        self.logger = logger
        configurationRepository = LLMConfigurationRepository(storage: storage)
        self.clientResolver = clientResolver
        snapshot = LLMRuntimeSnapshot(configuration: .openAI, clients: .empty)
        preparationState = .pending
    }

    /// Internal designated init: explicit configuration plus a client resolver.
    init(
        configuration: LLMConfiguration,
        clientResolver: any LLMClientResolving,
        logger: Logger
    ) {
        self.logger = logger
        configurationRepository = LLMConfigurationRepository(
            storage: InMemoryConfigurationService(config: configuration)
        )
        self.clientResolver = clientResolver
        snapshot = LLMRuntimeSnapshot(
            configuration: configuration,
            clients: configuration.isValid ? clientResolver.clients(for: configuration) : .empty
        )
        preparationState = .ready
    }

    // MARK: - Configuration Lifecycle

    public func loadConfiguration() async {
        await prepareIfNeeded()
        let config = await configurationRepository.load()
        apply(config)
        logLoaded(config)
    }

    public func restoreFromBackup() async throws {
        await prepareIfNeeded()
        if let restored = try await configurationRepository.restoreFromBackup() {
            logger.info("Restored configuration from backup")
            apply(restored)
        }
    }

    public func exportConfiguration() async throws -> Data {
        await prepareIfNeeded()
        return try await configurationRepository.exportConfiguration()
    }

    public func importConfiguration(from data: Data) async throws {
        await prepareIfNeeded()
        logger.info("Importing configuration")
        try await configurationRepository.importConfiguration(from: data)
        let config = await configurationRepository.load()
        apply(config)
        logLoaded(config)
    }

    public func updateConfiguration(_ config: LLMConfiguration) async throws {
        await prepareIfNeeded()
        let providerConfig = config.activeProviderConfiguration
        logger.info(
            "Updating configuration to models: \(providerConfig.modelName) / \(providerConfig.utilityModel) / \(providerConfig.fastModel)"
        )
        try await configurationRepository.save(config)
        apply(config)
    }

    public func clearConfiguration() async {
        await prepareIfNeeded()
        logger.warning("Clearing configuration")
        await configurationRepository.clear()
        apply(.openAI)
    }

    // MARK: - Dispatch

    public func fetchAvailableModels() async throws -> [String]? {
        await prepareIfNeeded()
        let resolved: ResolvedLLMClient
        do {
            resolved = try resolve(tier: .primary)
        } catch {
            return nil
        }
        return try await resolved.client.fetchAvailableModels()
    }

    // MARK: - Helpers

    private func logLoaded(_ configuration: LLMConfiguration) {
        if configuration.isValid {
            let providerConfig = configuration.activeProviderConfiguration
            let modelInfo = "Main: \(providerConfig.modelName), Utility: \(providerConfig.utilityModel), Fast: \(providerConfig.fastModel)"
            logger.info("Loaded configuration. \(modelInfo)")
        } else {
            logger.notice("LLM service not yet configured")
        }
    }
}
