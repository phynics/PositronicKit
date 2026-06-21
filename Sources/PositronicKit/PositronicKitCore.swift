import Foundation
import PKPrompt
import PKShared

/// The public facade for PositronicKitCore's agent runtime subsystem.
///
/// Accepts all required services as init parameters and wires them internally,
/// so consumers never need to assemble a shared dependency container.
///
/// Only `llmService` is required. All other parameters have sensible in-memory defaults
/// suitable for development and prototyping. For production, provide persistent stores.
///
/// PositronicKit intentionally stays transport-neutral. Concepts like timelines, workspaces,
/// agents, tool routing, and prompt assembly live here; concrete networking or multi-process hosting models are
/// expected to be provided downstream via injected stores, workspace creators, and connection hooks.
///
/// Intended extension seams for downstream applications are the facade itself plus public runtime
/// protocols such as persistence stores, `WorkspaceCreating` / `WorkspaceProtocol`,
/// `PromptSectionProviding`, and `ChatTurnPlugin`. Internal coordinators like `ChatEngine`,
/// `TimelinePromptHistory`, and the concrete turn pipeline remain runtime implementation details
/// even when they are visible to tests inside this package.
///
/// Example usage:
/// - Minimal: `PositronicKitCore(llmService: myLLM)`
/// - Production: use the grouped `persistence:` and `runtime:` initializers.
public struct PositronicKitCore: Sendable {
    // MARK: - Direct ChatEngine dependencies

    internal let llmService: any LLMServiceProtocol
    private let messageStore: any MessageStoreProtocol
    // Non-private so DependencySafetyTests can assert the facade reuses the injected timeline manager.
    let timelineManager: TimelineManager
    private let toolRouter: ToolRouter
    private let agentInstanceStore: any AgentInstanceStoreProtocol
    private let requestOriginStore: any RequestOriginStoreProtocol
    private var chatTurnPlugins: [any ChatTurnPlugin]
    private let defaultGenerationParameters: GenerationParameters?

    // MARK: - Transitive dependencies (TimelineManager, ContextManager)

    private let timelinePersistence: any TimelinePersistenceProtocol
    private let workspacePersistence: any WorkspacePersistenceProtocol
    private let memoryStore: any MemoryStoreProtocol
    private let toolPersistence: any ToolPersistenceProtocol
    private let agentTemplateStore: any AgentTemplateStoreProtocol
    private let embeddingService: any EmbeddingServiceProtocol

    private var chatEngine: ChatEngine

    // MARK: - Init

    /// A simplified initializer for common use cases.
    /// Provides sensible in-memory defaults for all stores.
    public init(
        llmService: any LLMServiceProtocol = UnconfiguredLLMService(),
        generationParameters: GenerationParameters? = nil
    ) {
        self.init(
            llmService: llmService,
            persistence: .inMemory(),
            generationParameters: generationParameters
        )
    }

    /// Initializes with all services required by the chat subsystem.
    ///
    /// This is the most flexible initializer, but it exposes concrete runtime wiring types such as
    /// `TimelineManager` and `ToolRouter`. Prefer the grouped `persistence:` and `runtime:`
    /// initializers when you want the facade to remain the primary public boundary.
    ///
    /// - Parameters:
    ///   - llmService: The LLM service to use for generation.
    ///   - messageStore: The store for persisting chat messages. Defaults to in-memory if nil.
    ///   - timelineManager: Manages timeline state, workspaces, and extensions. Auto-constructed if nil.
    ///   - toolRouter: Routes tool calls to the appropriate executor. Auto-constructed if nil.
    ///   - agentInstanceStore: Persistence for agent instance data. Defaults to in-memory if nil.
    ///   - requestOriginStore: Persistence for request-origin identity data. Defaults to in-memory if nil.
    ///   - timelinePersistence: Persistence for timeline records. Defaults to in-memory if nil.
    ///   - workspacePersistence: Persistence for workspace records. Defaults to in-memory if nil.
    ///   - memoryStore: Persistence for memory records. Defaults to in-memory if nil.
    ///   - toolPersistence: Persistence for tool references. Defaults to in-memory if nil.
    ///   - agentTemplateStore: Persistence for agent templates. Defaults to in-memory if nil.
    ///   - embeddingService: Embedding provider for context/memory search. Defaults to no-op if nil.
    ///   - workspaceRoot: Root directory for auto-constructed TimelineManager. Defaults to temp directory.
    ///   - chatTurnPlugins: Post-turn plugins (e.g. autonomous reactions).
    ///   - generationParameters: Optional default parameters for generation.
    public init(
        llmService: any LLMServiceProtocol,
        messageStore: (any MessageStoreProtocol)? = nil,
        timelineManager: TimelineManager? = nil,
        toolRouter: ToolRouter? = nil,
        agentInstanceStore: (any AgentInstanceStoreProtocol)? = nil,
        requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
        timelinePersistence: (any TimelinePersistenceProtocol)? = nil,
        workspacePersistence: (any WorkspacePersistenceProtocol)? = nil,
        memoryStore: (any MemoryStoreProtocol)? = nil,
        toolPersistence: (any ToolPersistenceProtocol)? = nil,
        agentTemplateStore: (any AgentTemplateStoreProtocol)? = nil,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        workspaceRoot: URL? = nil,
        chatTurnPlugins: [any ChatTurnPlugin] = [],
        generationParameters: GenerationParameters? = nil
    ) {
        self.llmService = llmService
        self.messageStore = messageStore ?? InMemoryMessageStore()
        self.agentInstanceStore = agentInstanceStore ?? InMemoryAgentInstanceStore()
        self.requestOriginStore = requestOriginStore ?? InMemoryRequestOriginStore()
        self.timelinePersistence = timelinePersistence ?? InMemoryTimelinePersistence()
        self.workspacePersistence = workspacePersistence ?? InMemoryWorkspacePersistence()
        self.memoryStore = memoryStore ?? InMemoryMemoryStore()
        self.toolPersistence = toolPersistence ?? InMemoryToolPersistence()
        self.agentTemplateStore = agentTemplateStore ?? InMemoryAgentTemplateStore()
        self.embeddingService = embeddingService ?? NoOpEmbeddingService()
        self.chatTurnPlugins = chatTurnPlugins
        self.defaultGenerationParameters = generationParameters

        let resolvedWorkspaceRoot = workspaceRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        let resolvedTimelineManager = timelineManager ?? TimelineManager(
            stores: .init(
                timelineStore: self.timelinePersistence,
                messageStore: self.messageStore,
                workspaceStore: self.workspacePersistence,
                toolPersistence: self.toolPersistence
            ),
            workspaceRoot: resolvedWorkspaceRoot
        )
        self.timelineManager = resolvedTimelineManager
        self.toolRouter = toolRouter ?? ToolRouter(
            timelineManager: resolvedTimelineManager,
            messageStore: self.messageStore
        )
        self.chatEngine = ChatEngine(
            dependencies: .init(
                timelineManager: resolvedTimelineManager,
                agentInstanceStore: self.agentInstanceStore,
                requestOriginStore: self.requestOriginStore,
                messageStore: self.messageStore,
                llmService: self.llmService,
                toolRouter: self.toolRouter,
                chatTurnPlugins: self.chatTurnPlugins
            )
        )
    }

    // MARK: - Builder

    /// Adds a custom stage to the chat execution pipeline.
    /// - Parameter stage: The custom pipeline stage to add.
    /// - Returns: A new instance with the stage added.
    ///
    /// This remains package-internal on purpose: the documented downstream extension surface is the
    /// facade plus higher-level hooks such as `ChatTurnPlugin` and `PromptSectionProviding`, not
    /// the concrete runtime pipeline topology.
    func addStage(_ stage: any PipelineStage<ChatTurnContext, ChatEvent>) -> PositronicKitCore {
        var copy = self
        copy.chatEngine.additionalStages.append(stage)
        return copy
    }

    /// Adds a chat turn plugin that runs after each LLM turn.
    /// - Parameter plugin: The plugin to add.
    /// - Returns: A new instance with the plugin added.
    public func addPlugin(_ plugin: any ChatTurnPlugin) -> PositronicKitCore {
        var copy = self
        copy.chatTurnPlugins.append(plugin)
        let existingStages = copy.chatEngine.additionalStages
        copy.chatEngine = ChatEngine(
            dependencies: .init(
                timelineManager: copy.timelineManager,
                agentInstanceStore: copy.agentInstanceStore,
                requestOriginStore: copy.requestOriginStore,
                messageStore: copy.messageStore,
                llmService: copy.llmService,
                toolRouter: copy.toolRouter,
                chatTurnPlugins: copy.chatTurnPlugins
            )
        )
        copy.chatEngine.additionalStages = existingStages
        return copy
    }

    // MARK: - Execution

    /// Run a chat turn and return a stream of events.
    /// - Parameters:
    ///   - timelineId: The unique identifier for the chat session.
    ///   - message: The user's input message.
    ///   - tools: Pre-resolved tools available for this turn.
    ///   - toolOutputs: Optional list of tool outputs submitted from a previous externally executed turn.
    ///   - systemInstructions: Optional system instructions to override the default.
    ///   - agentInstanceId: Optional identifier for the agent instance.
    ///   - maxTurns: Maximum number of LLM turns before stopping. Defaults to 5.
    ///   - generationParameters: Optional parameters for generation (overrides defaults).
    /// - Returns: An asynchronous stream of chat events.
    public func run(
        timelineId: UUID,
        message: String,
        tools: [AnyTool] = [],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        agentInstanceId: UUID? = nil,
        maxTurns: Int = 5,
        generationParameters: GenerationParameters? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let resolvedContextManager = await self.resolveContextManager(
            explicit: nil,
            timelineId: timelineId
        )

        return try await chatEngine.execute(
            timelineId: timelineId,
            message: message,
            tools: tools,
            toolOutputs: toolOutputs,
            contextManager: resolvedContextManager,
            systemInstructions: systemInstructions,
            agentInstanceId: agentInstanceId,
            maxTurns: maxTurns,
            generationParameters: generationParameters ?? self.defaultGenerationParameters
        )
    }

    private func resolveContextManager(
        explicit contextManager: ContextManager?,
        timelineId: UUID
    ) async -> ContextManager? {
        if let contextManager {
            return contextManager
        }

        if let existing = await timelineManager.getContextManager(for: timelineId) {
            return existing
        }

        try? await timelineManager.hydrateTimeline(id: timelineId)
        return await timelineManager.getContextManager(for: timelineId)
    }
}

// MARK: - PersistenceConfiguration

public extension PositronicKitCore {
    /// Groups all persistence stores for convenient initialization.
    ///
    /// Use this when your persistence layer provides all 8 stores.
    struct PersistenceConfiguration: Sendable {
        public let messageStore: any MessageStoreProtocol
        public let timelinePersistence: any TimelinePersistenceProtocol
        public let workspacePersistence: any WorkspacePersistenceProtocol
        public let memoryStore: any MemoryStoreProtocol
        public let toolPersistence: any ToolPersistenceProtocol
        public let agentInstanceStore: any AgentInstanceStoreProtocol
        public let requestOriginStore: any RequestOriginStoreProtocol
        public let agentTemplateStore: any AgentTemplateStoreProtocol

        public init(
            messageStore: any MessageStoreProtocol,
            timelinePersistence: any TimelinePersistenceProtocol,
            workspacePersistence: any WorkspacePersistenceProtocol,
            memoryStore: any MemoryStoreProtocol,
            toolPersistence: any ToolPersistenceProtocol,
            agentInstanceStore: any AgentInstanceStoreProtocol,
            requestOriginStore: any RequestOriginStoreProtocol,
            agentTemplateStore: any AgentTemplateStoreProtocol
        ) {
            self.messageStore = messageStore
            self.timelinePersistence = timelinePersistence
            self.workspacePersistence = workspacePersistence
            self.memoryStore = memoryStore
            self.toolPersistence = toolPersistence
            self.agentInstanceStore = agentInstanceStore
            self.requestOriginStore = requestOriginStore
            self.agentTemplateStore = agentTemplateStore
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
                requestOriginStore: InMemoryRequestOriginStore(),
                agentTemplateStore: InMemoryAgentTemplateStore()
            )
        }
    }

    /// Groups runtime-owned coordinators and defaults that would otherwise require exposing the
    /// concrete `TimelineManager` / `ToolRouter` pair directly in facade call sites.
    struct RuntimeConfiguration: Sendable {
        public let timelineManager: TimelineManager?
        public let toolRouter: ToolRouter?
        public let workspaceRoot: URL?
        public let chatTurnPlugins: [any ChatTurnPlugin]

        public init(
            timelineManager: TimelineManager? = nil,
            toolRouter: ToolRouter? = nil,
            workspaceRoot: URL? = nil,
            chatTurnPlugins: [any ChatTurnPlugin] = []
        ) {
            self.timelineManager = timelineManager
            self.toolRouter = toolRouter
            self.workspaceRoot = workspaceRoot
            self.chatTurnPlugins = chatTurnPlugins
        }

        public static func `default`() -> RuntimeConfiguration {
            RuntimeConfiguration()
        }
    }

    /// Creates a PositronicKitCore with grouped persistence configuration.
    ///
    /// - Parameters:
    ///   - llmService: The LLM service to use for generation (required).
    ///   - persistence: All persistence stores grouped together.
    ///   - embeddingService: Embedding provider. Defaults to no-op.
    ///   - timelineManager: Timeline orchestrator. Auto-constructed if nil.
    ///   - toolRouter: Tool routing. Auto-constructed if nil.
    ///   - workspaceRoot: Root directory for workspaces. Defaults to temp directory.
    ///   - chatTurnPlugins: Post-turn plugins. Defaults to none.
    ///   - generationParameters: Optional default parameters for generation.
    init(
        llmService: any LLMServiceProtocol,
        persistence: PersistenceConfiguration,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        timelineManager: TimelineManager? = nil,
        toolRouter: ToolRouter? = nil,
        workspaceRoot: URL? = nil,
        chatTurnPlugins: [any ChatTurnPlugin] = [],
        generationParameters: GenerationParameters? = nil
    ) {
        self.init(
            llmService: llmService,
            messageStore: persistence.messageStore,
            timelineManager: timelineManager,
            toolRouter: toolRouter,
            agentInstanceStore: persistence.agentInstanceStore,
            requestOriginStore: persistence.requestOriginStore,
            timelinePersistence: persistence.timelinePersistence,
            workspacePersistence: persistence.workspacePersistence,
            memoryStore: persistence.memoryStore,
            toolPersistence: persistence.toolPersistence,
            agentTemplateStore: persistence.agentTemplateStore,
            embeddingService: embeddingService,
            workspaceRoot: workspaceRoot,
            chatTurnPlugins: chatTurnPlugins,
            generationParameters: generationParameters
        )
    }

    /// Creates a PositronicKitCore with grouped persistence and grouped runtime configuration.
    init(
        llmService: any LLMServiceProtocol,
        persistence: PersistenceConfiguration,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        runtime: RuntimeConfiguration,
        generationParameters: GenerationParameters? = nil
    ) {
        self.init(
            llmService: llmService,
            messageStore: persistence.messageStore,
            timelineManager: runtime.timelineManager,
            toolRouter: runtime.toolRouter,
            agentInstanceStore: persistence.agentInstanceStore,
            requestOriginStore: persistence.requestOriginStore,
            timelinePersistence: persistence.timelinePersistence,
            workspacePersistence: persistence.workspacePersistence,
            memoryStore: persistence.memoryStore,
            toolPersistence: persistence.toolPersistence,
            agentTemplateStore: persistence.agentTemplateStore,
            embeddingService: embeddingService,
            workspaceRoot: runtime.workspaceRoot,
            chatTurnPlugins: runtime.chatTurnPlugins,
            generationParameters: generationParameters
        )
    }
}
