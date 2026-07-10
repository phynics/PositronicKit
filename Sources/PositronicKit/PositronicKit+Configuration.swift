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

    struct PersistenceConfiguration: Sendable {
        public let messageStore: any MessageStoreProtocol
        public let timelinePersistence: any TimelinePersistenceProtocol
        public let workspacePersistence: any WorkspacePersistenceProtocol
        public let memoryStore: any MemoryStoreProtocol
        public let toolPersistence: any ToolPersistenceProtocol
        public let agentInstanceStore: any AgentInstanceStoreProtocol
        public let requestOriginStore: any RequestOriginStoreProtocol

        public init(
            messageStore: any MessageStoreProtocol,
            timelinePersistence: any TimelinePersistenceProtocol,
            workspacePersistence: any WorkspacePersistenceProtocol,
            memoryStore: any MemoryStoreProtocol,
            toolPersistence: any ToolPersistenceProtocol,
            agentInstanceStore: any AgentInstanceStoreProtocol,
            requestOriginStore: any RequestOriginStoreProtocol
        ) {
            self.messageStore = messageStore
            self.timelinePersistence = timelinePersistence
            self.workspacePersistence = workspacePersistence
            self.memoryStore = memoryStore
            self.toolPersistence = toolPersistence
            self.agentInstanceStore = agentInstanceStore
            self.requestOriginStore = requestOriginStore
        }

        public static func inMemory() -> PersistenceConfiguration {
            PersistenceConfiguration(
                messageStore: InMemoryMessageStore(), timelinePersistence: InMemoryTimelinePersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(), memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(), agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            )
        }
    }

    struct RuntimeConfiguration: Sendable {
        public let workspaceCreator: any WorkspaceCreating
        public let sectionProviders: [any PromptSectionProviding]
        public let runtimeToolPolicy: TimelineManager.RuntimeToolPolicy
        public let workspaceRoot: URL?
        public let chatTurnPlugins: [any ChatTurnPlugin]
        public let turnInspector: (any TurnInspecting)?
        public let toolApprovalGate: any ToolApprovalGate

        public init(
            workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
            sectionProviders: [any PromptSectionProviding] = [],
            runtimeToolPolicy: TimelineManager.RuntimeToolPolicy = .default,
            workspaceRoot: URL? = nil,
            chatTurnPlugins: [any ChatTurnPlugin] = [],
            turnInspector: (any TurnInspecting)? = nil,
            toolApprovalGate: any ToolApprovalGate = DenyAllToolApprovalGate()
        ) {
            self.workspaceCreator = workspaceCreator
            self.sectionProviders = sectionProviders
            self.runtimeToolPolicy = runtimeToolPolicy
            self.workspaceRoot = workspaceRoot
            self.chatTurnPlugins = chatTurnPlugins
            self.turnInspector = turnInspector
            self.toolApprovalGate = toolApprovalGate
        }

        public static var `default`: RuntimeConfiguration { RuntimeConfiguration() }
    }

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
            turnInspector: configuration.runtime.turnInspector,
            generationParameters: configuration.generationParameters,
            toolApprovalGate: configuration.runtime.toolApprovalGate
        )
    }
}
