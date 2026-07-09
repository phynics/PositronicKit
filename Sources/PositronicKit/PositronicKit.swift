import ErrorKit
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

    let llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient
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
    private let logger = Logger.module(named: "positronickit-facade")

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
    /// Hosts that need fresh provider settings between sends should prefer `reconfigured(...)`,
    /// which preserves this state automatically. If a host still reconstructs whole facade
    /// values manually, it must inject the *same* registry instance into every facade it builds
    /// for a given app lifetime via the `promptHistoryRegistry:` init parameter below —
    /// otherwise each new facade gets a blank registry and both the journal diff data (YAK-16)
    /// and the persisted inspection-turn-index counter it carries reset on every send, causing
    /// `TimelinePromptHistory.nextInspectionTurnIndex()` to start over at 0 each time and
    /// collide with the prior send's persisted rows.
    private let promptHistoryRegistry: TimelinePromptHistoryRegistry
    private let workspaceRoot: URL?
    private let workspaceCreator: any WorkspaceCreating
    private let sectionProviders: [any PromptSectionProviding]
    private let runtimeToolPolicy: TimelineManager.RuntimeToolPolicy
    private let toolApprovalGate: any ToolApprovalGate

    // MARK: - Init

    /// A simplified initializer for common use cases.
    /// Provides sensible in-memory defaults for all stores.
    public init(
        llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient = UnconfiguredLLMService(),
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
    ///     fresh, private registry. Prefer `reconfigured(...)` when only provider settings
    ///     change between sends; if you still reconstruct whole facades manually, pass the
    ///     same registry instance every time or prompt-diff/inspection-turn-index state resets.
    ///   - generationParameters: Optional default parameters for generation.
    ///   - toolApprovalGate: Gate consulted at the runtime execution sink before any tool whose
    ///     `requiresPermission` is `true` runs. Defaults to `DenyAllToolApprovalGate` so
    ///     permissioned tools never execute without an explicitly injected approval path (YAK-31).
    public init(
        llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient,
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
        self.workspaceRoot = workspaceRoot
        self.workspaceCreator = workspaceCreator
        self.sectionProviders = sectionProviders
        self.runtimeToolPolicy = runtimeToolPolicy
        self.toolApprovalGate = toolApprovalGate
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
            embeddingService: self.embeddingService,
            promptHistoryRegistry: promptHistoryRegistry
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

    /// Returns a new facade with updated provider/generation configuration while preserving the
    /// current instance's runtime-owned cross-send state (prompt-history journal diffs and
    /// inspection turn indexing), stores, tools, plugins, and workspace wiring.
    ///
    /// This is the supported path for hosts that must refresh provider settings between sends
    /// without silently resetting per-timeline prompt-history state.
    public func reconfigured(
        llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient,
        generationParameters: GenerationParameters? = nil
    ) -> PositronicKit {
        PositronicKit(
            llmService: llmService,
            messageStore: messageStore,
            agentInstanceStore: agentInstanceStore,
            requestOriginStore: requestOriginStore,
            timelinePersistence: timelinePersistence,
            workspacePersistence: workspacePersistence,
            memoryStore: memoryStore,
            toolPersistence: toolPersistence,
            embeddingService: embeddingService,
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            chatTurnPlugins: chatTurnPlugins,
            turnInspector: turnInspector,
            promptHistoryRegistry: promptHistoryRegistry,
            generationParameters: generationParameters ?? defaultGenerationParameters,
            toolApprovalGate: toolApprovalGate
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
    func addingStage(_ stage: any PipelineStage<ChatTurnContext, ChatEvent>) -> PositronicKit {
        var copy = self
        copy.chatEngine.additionalStages.append(stage)
        return copy
    }

    /// Adds a chat turn plugin that runs after each LLM turn.
    /// - Parameter plugin: The plugin to add.
    /// - Returns: A new instance with the plugin added.
    public func addingPlugin(_ plugin: any ChatTurnPlugin) -> PositronicKit {
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
    /// - Parameter request: The full turn configuration.
    /// - Returns: An asynchronous stream of chat events.
    public func run(_ request: ChatRunRequest) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let resolvedContextManager = await resolveContextManager(
            explicit: nil,
            timelineId: request.timelineId
        )

        return try await chatEngine.execute(
            timelineId: request.timelineId,
            sendId: request.sendId,
            message: request.message,
            tools: request.tools,
            toolOutputs: request.toolOutputs,
            contextManager: resolvedContextManager,
            systemInstructions: request.systemInstructions,
            agentInstanceId: request.agentInstanceId,
            maxTurns: request.maxTurns,
            generationParameters: request.generationParameters ?? defaultGenerationParameters,
            structuredOutput: request.structuredOutput,
            sidecars: request.sidecars,
            includeSidecarMechanismPreamble: request.includeSidecarMechanismPreamble,
            assemblyLogger: request.promptAssemblyLogger
        )
    }

    /// Resolves the `ContextManager` for a turn, hydrating the timeline from persistence
    /// first if it isn't already cached in memory.
    ///
    /// Hydration failure is logged, not propagated: a brand-new (never-persisted) timeline
    /// legitimately has nothing to hydrate yet (`TimelineError.timelineNotFound`) — that is
    /// the expected first-message flow, not a fault. A transient store error looks identical
    /// from here, so both are logged at `.error` with the timeline ID and the turn proceeds
    /// with `contextManager == nil`; downstream turn setup creates a fresh context as needed.
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

        do {
            try await timelineManager.hydrateTimeline(id: timelineId)
        } catch {
            logger.error(
                "Failed to hydrate timeline \(timelineId) before turn start: \(ErrorKit.userFriendlyMessage(for: error)). Proceeding unhydrated."
            )
        }
        return await timelineManager.getContextManager(for: timelineId)
    }
}
