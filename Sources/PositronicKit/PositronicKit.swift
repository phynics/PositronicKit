import Foundation
import Logging
import PKPrompt
import PKShared

/// The public facade for PositronicKit's agent runtime subsystem.
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
/// - Minimal: `PositronicKit(llmService: myLLM)`
/// - Production: use the grouped `persistence:` and `runtime:` initializers.
public struct PositronicKit: Sendable {
    // MARK: - Direct ChatEngine dependencies

    let llmService: any LLMServiceProtocol
    private let messageStore: any MessageStoreProtocol

    /// The timeline manager built by this facade. Hosts that need direct access (e.g. to wire
    /// their own routes) should read this instead of building a second `TimelineManager`, which
    /// would silently diverge from the stores the facade itself uses.
    public let timelineManager: TimelineManager

    /// The tool router built by this facade, wired to `timelineManager` above.
    public let toolRouter: ToolRouter
    private let agentInstanceStore: any AgentInstanceStoreProtocol
    private let requestOriginStore: any RequestOriginStoreProtocol
    private var chatTurnPlugins: [any ChatTurnPlugin]
    private let turnInspector: (any TurnInspecting)?
    private let defaultGenerationParameters: GenerationParameters?

    // MARK: - Transitive dependencies (TimelineManager, ContextManager)

    private let timelinePersistence: any TimelinePersistenceProtocol
    private let workspacePersistence: any WorkspacePersistenceProtocol
    private let memoryStore: any MemoryStoreProtocol
    private let toolPersistence: any ToolPersistenceProtocol
    private let embeddingService: any EmbeddingServiceProtocol

    private var chatEngine: ChatEngine

    /// Per-timeline prompt-history/journal-diff state, shared across every `execute` call on
    /// this facade instance so a conversation's second and later sends diff against the
    /// previous send's prompt snapshot instead of starting from a blank slate each time.
    ///
    /// Hosts that reconstruct a fresh `PositronicKit` value per send (e.g. to pick up updated
    /// provider settings) must inject the *same* registry instance into every facade they
    /// build for a given app lifetime via the `promptHistoryRegistry:` init parameter below —
    /// otherwise each new facade gets a blank registry and both the journal diff data (YAK-16)
    /// and the persisted inspection-turn-index counter it carries reset on every send, causing
    /// `TimelinePromptHistory.nextInspectionTurnIndex()` to start over at 0 each time and
    /// collide with the prior send's persisted rows.
    private let promptHistoryRegistry: TimelinePromptHistoryRegistry

    // MARK: - Init

    /// A simplified initializer for common use cases.
    /// Provides sensible in-memory defaults for all stores.
    public init(
        llmService: any LLMServiceProtocol = UnconfiguredLLMService(),
        turnInspector: (any TurnInspecting)? = nil,
        generationParameters: GenerationParameters? = nil
    ) {
        self.init(
            llmService: llmService,
            persistence: .inMemory(),
            turnInspector: turnInspector,
            generationParameters: generationParameters
        )
    }

    /// Initializes with all services required by the chat subsystem.
    ///
    /// This is the most flexible initializer. The facade is the only place a `TimelineManager`
    /// and `ToolRouter` get built — there's no way to hand it pre-built instances of either, so
    /// they can never silently diverge from the stores passed in here. Callers that need the
    /// constructed instances afterward (e.g. to wire their own routes) should read them back via
    /// the `timelineManager` / `toolRouter` properties.
    ///
    /// Prefer the grouped `persistence:` and `runtime:` initializers when you want the facade to
    /// remain the primary public boundary.
    ///
    /// - Parameters:
    ///   - llmService: The LLM service to use for generation.
    ///   - messageStore: The store for persisting chat messages. Defaults to in-memory if nil.
    ///   - agentInstanceStore: Persistence for agent instance data. Defaults to in-memory if nil.
    ///   - requestOriginStore: Persistence for request-origin identity data. Defaults to in-memory if nil.
    ///   - timelinePersistence: Persistence for timeline records. Defaults to in-memory if nil.
    ///   - workspacePersistence: Persistence for workspace records. Defaults to in-memory if nil.
    ///   - memoryStore: Persistence for memory records. Defaults to in-memory if nil.
    ///   - toolPersistence: Persistence for tool references. Defaults to in-memory if nil.
    ///   - embeddingService: Embedding provider for context/memory search. Defaults to no-op if nil.
    ///   - workspaceRoot: Root directory for the facade-built TimelineManager. Defaults to temp directory.
    ///   - workspaceCreator: Workspace factory used by the facade-built TimelineManager. Defaults to `NullWorkspaceCreator()`.
    ///   - sectionProviders: Extension points for additional prompt sections, forwarded to TimelineManager.
    ///   - runtimeToolPolicy: Controls which built-in runtime tools TimelineManager installs.
    ///   - chatTurnPlugins: Post-turn plugins (e.g. autonomous reactions).
    ///   - turnInspector: Optional sink for per-turn prompt/journal inspection projections.
    ///   - promptHistoryRegistry: Per-timeline prompt-history/journal-diff state. Defaults to a
    ///     fresh, private registry. Hosts that reconstruct `PositronicKit` per send (e.g. to
    ///     read fresh provider settings) must pass the *same* registry instance into every
    ///     facade they build, or prompt-diff/inspection-turn-index state resets each send.
    ///   - generationParameters: Optional default parameters for generation.
    ///   - toolApprovalGate: Gate consulted at the runtime execution sink before any tool whose
    ///     `requiresPermission` is `true` runs. Defaults to `DenyAllToolApprovalGate` so
    ///     permissioned tools never execute without an explicitly injected approval path (YAK-31).
    public init(
        llmService: any LLMServiceProtocol,
        messageStore: (any MessageStoreProtocol)? = nil,
        agentInstanceStore: (any AgentInstanceStoreProtocol)? = nil,
        requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
        timelinePersistence: (any TimelinePersistenceProtocol)? = nil,
        workspacePersistence: (any WorkspacePersistenceProtocol)? = nil,
        memoryStore: (any MemoryStoreProtocol)? = nil,
        toolPersistence: (any ToolPersistenceProtocol)? = nil,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        workspaceRoot: URL? = nil,
        workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: TimelineManager.RuntimeToolPolicy = .default,
        chatTurnPlugins: [any ChatTurnPlugin] = [],
        turnInspector: (any TurnInspecting)? = nil,
        promptHistoryRegistry: TimelinePromptHistoryRegistry = TimelinePromptHistoryRegistry(),
        generationParameters: GenerationParameters? = nil,
        toolApprovalGate: any ToolApprovalGate = DenyAllToolApprovalGate()
    ) {
        self.llmService = llmService
        self.messageStore = messageStore ?? InMemoryMessageStore()
        self.agentInstanceStore = agentInstanceStore ?? InMemoryAgentInstanceStore()
        self.requestOriginStore = requestOriginStore ?? InMemoryRequestOriginStore()
        self.timelinePersistence = timelinePersistence ?? InMemoryTimelinePersistence()
        self.workspacePersistence = workspacePersistence ?? InMemoryWorkspacePersistence()
        self.memoryStore = memoryStore ?? InMemoryMemoryStore()
        self.toolPersistence = toolPersistence ?? InMemoryToolPersistence()
        self.embeddingService = embeddingService ?? NoOpEmbeddingService()
        self.chatTurnPlugins = chatTurnPlugins
        self.turnInspector = turnInspector
        self.promptHistoryRegistry = promptHistoryRegistry
        defaultGenerationParameters = generationParameters

        let resolvedWorkspaceRoot = workspaceRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        // The facade is the only place a TimelineManager gets built: every store it wraps
        // comes from the same `persistence` surface the rest of the facade uses, so there is
        // no seam where ChatEngine and TimelineManager can end up looking at different stores.
        let resolvedTimelineManager = TimelineManager(
            stores: .init(
                timelineStore: self.timelinePersistence,
                messageStore: self.messageStore,
                workspaceStore: self.workspacePersistence,
                toolPersistence: self.toolPersistence,
                memoryStore: self.memoryStore
            ),
            workspaceRoot: resolvedWorkspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: self.embeddingService
        )
        timelineManager = resolvedTimelineManager
        toolRouter = ToolRouter(
            timelineManager: resolvedTimelineManager,
            messageStore: self.messageStore,
            approvalGate: toolApprovalGate
        )
        chatEngine = ChatEngine(
            dependencies: .init(
                timelineManager: resolvedTimelineManager,
                agentInstanceStore: self.agentInstanceStore,
                requestOriginStore: self.requestOriginStore,
                messageStore: self.messageStore,
                llmService: self.llmService,
                toolRouter: toolRouter,
                chatTurnPlugins: self.chatTurnPlugins,
                turnInspector: self.turnInspector,
                promptHistoryRegistry: promptHistoryRegistry
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
    func addStage(_ stage: any PipelineStage<ChatTurnContext, ChatEvent>) -> PositronicKit {
        var copy = self
        copy.chatEngine.additionalStages.append(stage)
        return copy
    }

    /// Adds a chat turn plugin that runs after each LLM turn.
    /// - Parameter plugin: The plugin to add.
    /// - Returns: A new instance with the plugin added.
    public func addPlugin(_ plugin: any ChatTurnPlugin) -> PositronicKit {
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
                chatTurnPlugins: copy.chatTurnPlugins,
                turnInspector: copy.turnInspector,
                promptHistoryRegistry: copy.promptHistoryRegistry
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
    ///   - structuredOutput: Optional provider-enforced structured output request for the turn.
    ///   - sidecars: Optional piggy-backed auxiliary generations (title, summary, tone, etc.)
    ///     riding the same request as this turn's response. Mutually exclusive with
    ///     `structuredOutput` — passing both throws `SidecarError.conflictsWithExplicitStructuredOutput`.
    ///   - promptAssemblyLogger: Optional `swift-log` logger that enables prompt-assembly
    ///     diagnostics for this turn (stage execution, section resolution, and token-budget
    ///     decisions). Control verbosity through the logger's log level. Defaults to no diagnostics.
    /// - Returns: An asynchronous stream of chat events.
    public func run(
        timelineId: UUID,
        message: String,
        tools: [AnyTool] = [],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        agentInstanceId: UUID? = nil,
        maxTurns: Int = 5,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        promptAssemblyLogger: Logger? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let resolvedContextManager = await resolveContextManager(
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
            generationParameters: generationParameters ?? defaultGenerationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            assemblyLogger: promptAssemblyLogger
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

public extension PositronicKit {
    typealias PromptBuildContext = PositronicKitPromptBuildContext

    /// Groups all persistence stores for convenient initialization.
    ///
    /// Use this when your persistence layer provides all stores.
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

        public init(
            workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
            sectionProviders: [any PromptSectionProviding] = [],
            runtimeToolPolicy: TimelineManager.RuntimeToolPolicy = .default,
            workspaceRoot: URL? = nil,
            chatTurnPlugins: [any ChatTurnPlugin] = [],
            turnInspector: (any TurnInspecting)? = nil
        ) {
            self.workspaceCreator = workspaceCreator
            self.sectionProviders = sectionProviders
            self.runtimeToolPolicy = runtimeToolPolicy
            self.workspaceRoot = workspaceRoot
            self.chatTurnPlugins = chatTurnPlugins
            self.turnInspector = turnInspector
        }

        public static func `default`() -> RuntimeConfiguration {
            RuntimeConfiguration()
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
    init(
        llmService: any LLMServiceProtocol,
        persistence: PersistenceConfiguration,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        workspaceRoot: URL? = nil,
        chatTurnPlugins: [any ChatTurnPlugin] = [],
        turnInspector: (any TurnInspecting)? = nil,
        promptHistoryRegistry: TimelinePromptHistoryRegistry = TimelinePromptHistoryRegistry(),
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
            workspaceRoot: workspaceRoot,
            chatTurnPlugins: chatTurnPlugins,
            turnInspector: turnInspector,
            promptHistoryRegistry: promptHistoryRegistry,
            generationParameters: generationParameters
        )
    }

    /// Creates a PositronicKit with grouped persistence and grouped runtime configuration.
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
            generationParameters: generationParameters
        )
    }
}

@available(*, deprecated, renamed: "PositronicKit")
public typealias PositronicKitCore = PositronicKit
