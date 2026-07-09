import Foundation
import PKShared

// MARK: - PersistenceConfiguration

public extension PositronicKit {
    /// Groups all persistence stores for convenient initialization.
    ///
    /// Use this when your persistence layer provides all stores as a unit. Each store is still
    /// a separate protocol, so hosts can mix in-memory, GRDB, or custom backends per store.
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

        /// Provides a configuration with sensible in-memory defaults for all stores.
        public static func inMemory() -> PersistenceConfiguration {
            PersistenceConfiguration(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            )
        }
    }

    /// Creates a PositronicKit with grouped persistence configuration.
    ///
    /// - Parameters:
    ///   - llmService: The LLM service to use for generation (required).
    ///   - persistence: All persistence stores grouped together.
    ///   - embeddingService: Embedding provider. Defaults to no-op.
    ///   - workspaceRoot: Root directory for workspaces. Defaults to temp directory.
    ///   - chatTurnPlugins: Post-turn plugins. Defaults to none.
    ///   - turnInspector: Optional sink for per-turn prompt/journal inspection projections.
    ///   - promptHistoryRegistry: Per-timeline prompt-history/journal-diff state. See the main
    ///     initializer's doc comment for why hosts that rebuild `PositronicKit` per send must
    ///     pass the same instance every time.
    ///   - generationParameters: Optional default parameters for generation.
    ///   - toolApprovalGate: Gate consulted before any permissioned tool runs. Defaults to
    ///     `DenyAllToolApprovalGate` so permissioned tools never execute without an explicit
    ///     approval path; see the main initializer's doc comment (YAK-31).
    init(
        llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient,
        persistence: PersistenceConfiguration,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        workspaceRoot: URL? = nil,
        chatTurnPlugins: [any ChatTurnPlugin] = [],
        turnInspector: (any TurnInspecting)? = nil,
        promptHistoryRegistry: TimelinePromptHistoryRegistry = TimelinePromptHistoryRegistry(),
        generationParameters: GenerationParameters? = nil,
        toolApprovalGate: any ToolApprovalGate = DenyAllToolApprovalGate()
    ) {
        self.init(
            llmService: llmService,
            messageStore: persistence.messageStore,
            agentInstanceStore: persistence.agentInstanceStore,
            requestOriginStore: persistence.requestOriginStore,
            timelinePersistence: persistence.timelinePersistence,
            workspacePersistence: persistence.workspacePersistence,
            memoryStore: persistence.memoryStore,
            toolPersistence: persistence.toolPersistence,
            embeddingService: embeddingService,
            workspaceRoot: workspaceRoot,
            chatTurnPlugins: chatTurnPlugins,
            turnInspector: turnInspector,
            promptHistoryRegistry: promptHistoryRegistry,
            generationParameters: generationParameters,
            toolApprovalGate: toolApprovalGate
        )
    }
}

// MARK: - RuntimeConfiguration

public extension PositronicKit {
    /// Groups the non-store runtime knobs that `TimelineManager` needs but that aren't
    /// persistence stores: workspace creation strategy, prompt extension sections, and runtime
    /// tool policy, plus facade-level concerns like workspace root and chat turn plugins.
    ///
    /// There is intentionally no way to pass a pre-built `TimelineManager` or `ToolRouter` here —
    /// the facade always constructs both itself from `PersistenceConfiguration` plus these knobs,
    /// so the two can never end up wrapping different stores. Read the constructed instances back
    /// via `chat.timelineManager` / `chat.toolRouter` if you need them after construction.
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

        public static func `default`() -> RuntimeConfiguration {
            RuntimeConfiguration()
        }
    }

    /// Creates a PositronicKit with grouped persistence and grouped runtime configuration.
    init(
        llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient,
        persistence: PersistenceConfiguration,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        runtime: RuntimeConfiguration,
        generationParameters: GenerationParameters? = nil
    ) {
        self.init(
            llmService: llmService,
            messageStore: persistence.messageStore,
            agentInstanceStore: persistence.agentInstanceStore,
            requestOriginStore: persistence.requestOriginStore,
            timelinePersistence: persistence.timelinePersistence,
            workspacePersistence: persistence.workspacePersistence,
            memoryStore: persistence.memoryStore,
            toolPersistence: persistence.toolPersistence,
            embeddingService: embeddingService,
            workspaceRoot: runtime.workspaceRoot,
            workspaceCreator: runtime.workspaceCreator,
            sectionProviders: runtime.sectionProviders,
            runtimeToolPolicy: runtime.runtimeToolPolicy,
            chatTurnPlugins: runtime.chatTurnPlugins,
            turnInspector: runtime.turnInspector,
            generationParameters: generationParameters,
            toolApprovalGate: runtime.toolApprovalGate
        )
    }
}
