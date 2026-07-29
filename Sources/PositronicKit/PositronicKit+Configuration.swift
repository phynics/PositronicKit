import Foundation
import Logging
import PKShared
import PKUtilities

public extension PositronicKit {
    /// Groups provider-facing services used by the runtime.
    /// Embeddings stay with the LLM service because both are provider integrations.
    struct ProviderConfiguration: Sendable {
        public let languageModel: any LanguageModel
        public let embeddingService: (any EmbeddingServiceProtocol)?

        @available(*, deprecated, renamed: "languageModel")
        public var llmService: any LanguageModel { languageModel }

        public init(
            languageModel: any LanguageModel,
            embeddingService: (any EmbeddingServiceProtocol)? = nil
        ) {
            self.languageModel = languageModel
            self.embeddingService = embeddingService
        }

        @available(*, deprecated, renamed: "init(languageModel:embeddingService:)")
        public init(
            llmService: any LanguageModel,
            embeddingService: (any EmbeddingServiceProtocol)? = nil
        ) {
            self.init(languageModel: llmService, embeddingService: embeddingService)
        }

        @available(*, deprecated, renamed: "init(languageModel:embeddingService:)")
        public init(
            llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient,
            embeddingService: (any EmbeddingServiceProtocol)? = nil
        ) {
            self.init(languageModel: AnyLanguageModel(base: llmService), embeddingService: embeddingService)
        }
    }

    /// Groups provider, persistence, runtime, and generation concerns for construction.
    struct Configuration: Sendable {
        public let provider: ProviderConfiguration
        public let persistence: PersistenceConfiguration
        public let runtime: RuntimeConfiguration
        public let generationParameters: GenerationParameters?
        public let logging: LoggingConfiguration

        public init(
            provider: ProviderConfiguration,
            persistence: PersistenceConfiguration,
            runtime: RuntimeConfiguration = .default,
            generationParameters: GenerationParameters? = nil,
            logging: LoggingConfiguration = .default
        ) {
            self.provider = provider
            self.persistence = persistence
            self.runtime = runtime
            self.generationParameters = generationParameters
            self.logging = logging
        }
    }

    /// Groups the persistence stores the runtime writes to. Every store is optional;
    /// omitted stores default to their in-memory implementation, so partial persistence
    /// setups (e.g. only a real message store) work without boilerplate.
    ///
    /// Use ``validateDurability()`` to detect mixed-durability configurations (some stores
    /// durable, others in-memory) that can lose data on restart. Use
    /// ``fullyPersistent(messageStore:timelinePersistence:workspacePersistence:memoryStore:toolPersistence:agentInstanceStore:requestOriginStore:)``
    /// when all seven stores must be explicitly provided for full durability.
    struct PersistenceConfiguration: Sendable {
        public let messageStore: any MessageStoreProtocol
        public let timelinePersistence: any TimelinePersistenceProtocol
        public let workspacePersistence: any WorkspaceStore
        public let memoryStore: any MemoryStoreProtocol
        public let toolPersistence: any ToolPersistenceProtocol
        public let agentInstanceStore: any AgentInstanceStoreProtocol
        public let requestOriginStore: any RequestOriginStoreProtocol

        public init(
            messageStore: (any MessageStoreProtocol)? = nil,
            timelinePersistence: (any TimelinePersistenceProtocol)? = nil,
            workspacePersistence: (any WorkspaceStore)? = nil,
            memoryStore: (any MemoryStoreProtocol)? = nil,
            toolPersistence: (any ToolPersistenceProtocol)? = nil,
            agentInstanceStore: (any AgentInstanceStoreProtocol)? = nil,
            requestOriginStore: (any RequestOriginStoreProtocol)? = nil
        ) {
            self.messageStore = messageStore ?? InMemoryMessageStore()
            self.timelinePersistence = timelinePersistence ?? InMemoryTimelinePersistence()
            self.workspacePersistence = workspacePersistence ?? InMemoryWorkspacePersistence()
            self.memoryStore = memoryStore ?? InMemoryMemoryStore()
            self.toolPersistence = toolPersistence ?? InMemoryToolPersistence()
            self.agentInstanceStore = agentInstanceStore ?? InMemoryAgentInstanceStore()
            self.requestOriginStore = requestOriginStore ?? InMemoryRequestOriginStore()
        }

        /// A fully in-memory persistence configuration, suitable for prototyping and tests.
        public static func inMemory() -> PersistenceConfiguration {
            PersistenceConfiguration()
        }

        /// Requires all seven stores explicitly — the "full durability" entry point for
        /// production hosts (Monad, Shuttle). Unlike the optional-store init, no store can
        /// silently default to in-memory.
        public static func fullyPersistent(
            messageStore: any MessageStoreProtocol,
            timelinePersistence: any TimelinePersistenceProtocol,
            workspacePersistence: any WorkspaceStore,
            memoryStore: any MemoryStoreProtocol,
            toolPersistence: any ToolPersistenceProtocol,
            agentInstanceStore: any AgentInstanceStoreProtocol,
            requestOriginStore: any RequestOriginStoreProtocol
        ) -> PersistenceConfiguration {
            PersistenceConfiguration(
                messageStore: messageStore,
                timelinePersistence: timelinePersistence,
                workspacePersistence: workspacePersistence,
                memoryStore: memoryStore,
                toolPersistence: toolPersistence,
                agentInstanceStore: agentInstanceStore,
                requestOriginStore: requestOriginStore
            )
        }

        /// Classifies each store as `.durable` or `.ephemeral` based on its `isDurable` property.
        ///
        /// Use `report.isMixed` to detect configurations where some stores survive restart
        /// and others do not — a data-consistency risk. Use `report.ephemeralStoreNames` to
        /// identify which specific stores are ephemeral.
        public func validateDurability() -> DurabilityReport {
            DurabilityReport(
                messageStore: messageStore.isDurable ? .durable : .ephemeral,
                timelinePersistence: timelinePersistence.isDurable ? .durable : .ephemeral,
                workspacePersistence: workspacePersistence.isDurable ? .durable : .ephemeral,
                memoryStore: memoryStore.isDurable ? .durable : .ephemeral,
                toolPersistence: toolPersistence.isDurable ? .durable : .ephemeral,
                agentInstanceStore: agentInstanceStore.isDurable ? .durable : .ephemeral,
                requestOriginStore: requestOriginStore.isDurable ? .durable : .ephemeral
            )
        }
    }

    /// Whether a persistence store survives process restart.
    enum StoreDurability: Sendable, Equatable {
        /// The store is backed by a durable database (GRDB, SwiftData) and survives restart.
        case durable
        /// The store is in-memory/ephemeral and loses all data on restart.
        case ephemeral
    }

    /// A cross-store durability classification produced by
    /// ``PersistenceConfiguration/validateDurability()``.
    ///
    /// `isMixed` is `true` when the configuration has both `.durable` and `.ephemeral`
    /// stores — a data-consistency risk because durable stores may reference entities
    /// (timelines, workspaces, agents) that will be missing after restart.
    struct DurabilityReport: Sendable, Equatable {
        public let messageStore: StoreDurability
        public let timelinePersistence: StoreDurability
        public let workspacePersistence: StoreDurability
        public let memoryStore: StoreDurability
        public let toolPersistence: StoreDurability
        public let agentInstanceStore: StoreDurability
        public let requestOriginStore: StoreDurability

        public init(
            messageStore: StoreDurability,
            timelinePersistence: StoreDurability,
            workspacePersistence: StoreDurability,
            memoryStore: StoreDurability,
            toolPersistence: StoreDurability,
            agentInstanceStore: StoreDurability,
            requestOriginStore: StoreDurability
        ) {
            self.messageStore = messageStore
            self.timelinePersistence = timelinePersistence
            self.workspacePersistence = workspacePersistence
            self.memoryStore = memoryStore
            self.toolPersistence = toolPersistence
            self.agentInstanceStore = agentInstanceStore
            self.requestOriginStore = requestOriginStore
        }

        public var isMixed: Bool {
            let all: [StoreDurability] = [
                messageStore, timelinePersistence, workspacePersistence,
                memoryStore, toolPersistence, agentInstanceStore, requestOriginStore,
            ]
            return all.contains(.durable) && all.contains(.ephemeral)
        }

        /// The label of each store classified as `.ephemeral`, in declaration order.
        public var ephemeralStoreNames: [String] {
            var names: [String] = []
            if messageStore == .ephemeral { names.append("messageStore") }
            if timelinePersistence == .ephemeral { names.append("timelinePersistence") }
            if workspacePersistence == .ephemeral { names.append("workspacePersistence") }
            if memoryStore == .ephemeral { names.append("memoryStore") }
            if toolPersistence == .ephemeral { names.append("toolPersistence") }
            if agentInstanceStore == .ephemeral { names.append("agentInstanceStore") }
            if requestOriginStore == .ephemeral { names.append("requestOriginStore") }
            return names
        }

        /// The warning message logged on mixed durability, or `nil` when the configuration
        /// is uniformly durable or uniformly ephemeral.
        public var mixedDurabilityWarning: String? {
            guard isMixed else { return nil }
            return "Mixed durability: the following stores are in-memory and will not survive restart: \(ephemeralStoreNames.joined(separator: ", ")). Data persisted to durable stores may reference entities that will be missing after restart."
        }
    }

    /// Groups the non-store runtime knobs: workspace creation, prompt-section providers,
    /// tool policy and approval, chat-turn plugins, and prompt observation.
    struct RuntimeConfiguration: Sendable {
        public let workspaceCreator: any WorkspaceFactory
        public let sectionProviders: [any PromptSectionProviding]
        public let runtimeToolPolicy: TimelineManager.RuntimeToolPolicy
        public let workspaceRoot: URL?
        public let chatTurnPlugins: [any ChatTurnPlugin]
        public let promptObserver: (any PromptObserving)?
        public let toolApprovalPolicy: any ToolApprovalPolicy
        public let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration

        public init(
            workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
            sectionProviders: [any PromptSectionProviding] = [],
            runtimeToolPolicy: TimelineManager.RuntimeToolPolicy = .default,
            workspaceRoot: URL? = nil,
            chatTurnPlugins: [any ChatTurnPlugin] = [],
            promptObserver: (any PromptObserving)? = nil,
            toolApprovalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
            diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default
        ) {
            self.workspaceCreator = workspaceCreator
            self.sectionProviders = sectionProviders
            self.runtimeToolPolicy = runtimeToolPolicy
            self.workspaceRoot = workspaceRoot
            self.chatTurnPlugins = chatTurnPlugins
            self.promptObserver = promptObserver
            self.toolApprovalPolicy = toolApprovalPolicy
            self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
        }

        /// The default runtime configuration: no workspaces, no plugins, deny-all tool approval.
        public static var `default`: RuntimeConfiguration {
            RuntimeConfiguration()
        }
    }

    /// Creates a facade from a grouped configuration. This is the supported production entry
    /// point; use `PositronicKit(llmService:)` for prototyping.
    ///
    /// During construction the persistence configuration is checked for mixed durability
    /// (some stores durable, others in-memory). If mixed, a `.warning` is logged naming the
    /// specific ephemeral stores. The warning is non-fatal — it is the guardrail against
    /// accidentally losing timelines, workspaces, agents, or tool state on restart.
    convenience init(configuration: Configuration) {
        self.init(
            languageModel: configuration.provider.languageModel,
            messageStore: configuration.persistence.messageStore,
            agentInstanceStore: configuration.persistence.agentInstanceStore,
            requestOriginStore: configuration.persistence.requestOriginStore,
            timelinePersistence: configuration.persistence.timelinePersistence,
            workspacePersistence: configuration.persistence.workspacePersistence,
            memoryStore: configuration.persistence.memoryStore,
            toolPersistence: configuration.persistence.toolPersistence,
            embeddingService: configuration.provider.embeddingService,
            workspaceRoot: configuration.runtime.workspaceRoot,
            workspaceCreator: configuration.runtime.workspaceCreator,
            sectionProviders: configuration.runtime.sectionProviders,
            runtimeToolPolicy: configuration.runtime.runtimeToolPolicy,
            chatTurnPlugins: configuration.runtime.chatTurnPlugins,
            promptObserver: configuration.runtime.promptObserver,
            diagnosticSnapshotConfiguration: configuration.runtime.diagnosticSnapshotConfiguration,
            generationParameters: configuration.generationParameters,
            toolApprovalPolicy: configuration.runtime.toolApprovalPolicy,
            loggingConfiguration: configuration.logging,
            sharedRegistry: TimelinePromptJournals(),
            additionalStages: []
        )
        if let warning = configuration.persistence.validateDurability().mixedDurabilityWarning {
            configuration.logging.logger(named: "positronickit-facade").warning(
                "\(configuration.logging.redactionPolicy.sanitizeStructured(warning))"
            )
        }
    }
}
