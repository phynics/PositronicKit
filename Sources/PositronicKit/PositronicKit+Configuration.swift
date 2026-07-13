import Foundation
import PKShared

public extension PositronicKit {
    /// Groups provider-facing services used by the runtime.
    /// Embeddings stay with the LLM service because both are provider integrations.
    struct ProviderConfiguration: Sendable {
        public let llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient
        public let embeddingService: (any EmbeddingServiceProtocol)?

        public init(
            llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient,
            embeddingService: (any EmbeddingServiceProtocol)? = nil
        ) {
            self.llmService = llmService
            self.embeddingService = embeddingService
        }
    }

    /// Groups provider, persistence, runtime, and generation concerns for construction.
    struct Configuration: Sendable {
        public let provider: ProviderConfiguration
        public let persistence: PersistenceConfiguration
        public let runtime: RuntimeConfiguration
        public let generationParameters: GenerationParameters?

        public init(
            provider: ProviderConfiguration,
            persistence: PersistenceConfiguration,
            runtime: RuntimeConfiguration = .default,
            generationParameters: GenerationParameters? = nil
        ) {
            self.provider = provider
            self.persistence = persistence
            self.runtime = runtime
            self.generationParameters = generationParameters
        }
    }

    /// Groups the persistence stores the runtime writes to. Every store is optional;
    /// omitted stores default to their in-memory implementation, so partial persistence
    /// setups (e.g. only a real message store) work without boilerplate.
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

        public init(
            workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
            sectionProviders: [any PromptSectionProviding] = [],
            runtimeToolPolicy: TimelineManager.RuntimeToolPolicy = .default,
            workspaceRoot: URL? = nil,
            chatTurnPlugins: [any ChatTurnPlugin] = [],
            promptObserver: (any PromptObserving)? = nil,
            toolApprovalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy()
        ) {
            self.workspaceCreator = workspaceCreator
            self.sectionProviders = sectionProviders
            self.runtimeToolPolicy = runtimeToolPolicy
            self.workspaceRoot = workspaceRoot
            self.chatTurnPlugins = chatTurnPlugins
            self.promptObserver = promptObserver
            self.toolApprovalPolicy = toolApprovalPolicy
        }

        /// The default runtime configuration: no workspaces, no plugins, deny-all tool approval.
        public static var `default`: RuntimeConfiguration {
            RuntimeConfiguration()
        }
    }

    /// Creates a facade from a grouped configuration. This is the supported production entry
    /// point; use `PositronicKit(llmService:)` for prototyping.
    convenience init(configuration: Configuration) {
        self.init(
            llmService: configuration.provider.llmService,
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
            generationParameters: configuration.generationParameters,
            toolApprovalPolicy: configuration.runtime.toolApprovalPolicy,
            sharedRegistry: TimelinePromptJournals(),
            additionalStages: []
        )
    }
}
