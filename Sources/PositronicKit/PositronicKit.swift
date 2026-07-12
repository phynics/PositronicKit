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
/// - Production: use `PositronicKit(configuration:)`.
///
/// The public operation ladder is progressive: tier 1 is timeline-free one-shot
/// `complete(_:)`/`stream(_:)`; tier 2 is the stateful `Conversation` cursor; tier 3 is
/// direct `timelineManager` access; tier 4 is the full `AgenticRuntime` tool/agent loop;
/// tier 5 is the raw primitives (`toolRouter`, `llmService`, and the prompt DSL) for a
/// bespoke pipeline. A typical application wraps one kit in an application-owned Service
/// class, then passes the managers or controllers it vends to the relevant subsystems.
///
/// Construct once and hold for the app's lifetime. `PositronicKit` is a reference type;
/// constructing a new instance starts a new, independent cross-send history.
public final class PositronicKit: Sendable {
    // MARK: - Direct ChatEngine dependencies

    let llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient
    private let messageStore: any MessageStoreProtocol

    /// The timeline manager built by this facade. Hosts that need direct access (e.g. to wire
    /// their own routes) should read this instead of building a second `TimelineManager`, which
    /// would silently diverge from the stores the facade itself uses.
    public let timelineManager: TimelineManager

    /// The single agent-instance manager owned by this facade. It is wired to the same
    /// timeline manager and persistence stores as the rest of the runtime.
    public let agentInstanceManager: AgentInstanceManager

    /// The tool router built by this facade, wired to `timelineManager` above.
    public let toolRouter: ToolRouter
    private let agentInstanceStore: any AgentInstanceStoreProtocol
    private let requestOriginStore: any RequestOriginStoreProtocol
    private let chatTurnPlugins: [any ChatTurnPlugin]
    private let promptInspector: (any PromptInspecting)?
    let defaultGenerationParameters: GenerationParameters?
    private let logger = Logger.module(named: "positronickit-facade")

    // MARK: - Transitive dependencies (TimelineManager, ContextManager)

    private let timelinePersistence: any TimelinePersistenceProtocol
    private let workspacePersistence: any WorkspacePersistenceProtocol
    private let memoryStore: any MemoryStoreProtocol
    private let toolPersistence: any ToolPersistenceProtocol
    private let embeddingService: any EmbeddingServiceProtocol

    private let chatEngine: ChatEngine

    /// Owned internally; every conversation vended by this instance shares it automatically.
    /// Construct a new `PositronicKit` for a genuinely separate cross-send history.
    private let promptHistoryRegistry: TimelinePromptHistoryRegistry
    private let workspaceRoot: URL?
    private let workspaceCreator: any WorkspaceCreating
    private let sectionProviders: [any PromptSectionProviding]
    private let runtimeToolPolicy: TimelineManager.RuntimeToolPolicy
    private let toolApprovalPolicy: any ToolApprovalPolicy

    // MARK: - Init

    /// Creates a provider-agnostic facade with in-memory persistence and default runtime policy.
    public convenience init(
        llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient = UnconfiguredLLMService()
    ) {
        self.init(
            configuration: .init(
                provider: .init(llmService: llmService),
                persistence: .inMemory()
            )
        )
    }

    init(
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
        promptInspector: (any PromptInspecting)? = nil,
        generationParameters: GenerationParameters? = nil,
        toolApprovalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
        sharedRegistry: TimelinePromptHistoryRegistry,
        additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>]
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
        self.promptInspector = promptInspector
        promptHistoryRegistry = sharedRegistry
        self.workspaceRoot = workspaceRoot
        self.workspaceCreator = workspaceCreator
        self.sectionProviders = sectionProviders
        self.runtimeToolPolicy = runtimeToolPolicy
        self.toolApprovalPolicy = toolApprovalPolicy
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
        agentInstanceManager = AgentInstanceManager(
            repository: AgentWorkspaceService(
                workspaceRoot: resolvedWorkspaceRoot,
                workspacePersistence: self.workspacePersistence
            ),
            stores: .init(
                instanceStore: self.agentInstanceStore,
                timelineStore: self.timelinePersistence,
                messageStore: self.messageStore,
                workspaceStore: self.workspacePersistence
            ),
            timelineManager: resolvedTimelineManager
        )
        toolRouter = ToolRouter(
            timelineManager: resolvedTimelineManager,
            messageStore: self.messageStore,
            approvalPolicy: toolApprovalPolicy
        )
        var engine = ChatEngine(
            dependencies: .init(
                timelineManager: resolvedTimelineManager,
                agentInstanceStore: self.agentInstanceStore,
                requestOriginStore: self.requestOriginStore,
                messageStore: self.messageStore,
                llmService: self.llmService,
                toolRouter: toolRouter,
                chatTurnPlugins: self.chatTurnPlugins,
                promptInspector: self.promptInspector,
                promptHistoryRegistry: promptHistoryRegistry
            )
        )
        engine.additionalStages = additionalStages
        chatEngine = engine
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
            promptInspector: promptInspector,
            generationParameters: generationParameters ?? defaultGenerationParameters,
            toolApprovalPolicy: toolApprovalPolicy,
            sharedRegistry: promptHistoryRegistry,
            additionalStages: chatEngine.additionalStages
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
            promptInspector: promptInspector,
            generationParameters: defaultGenerationParameters,
            toolApprovalPolicy: toolApprovalPolicy,
            sharedRegistry: promptHistoryRegistry,
            additionalStages: chatEngine.additionalStages + [stage]
        )
    }

    /// Adds a chat turn plugin that runs after each LLM turn.
    /// - Parameter plugin: The plugin to add.
    /// - Returns: A new instance with the plugin added.
    public func addingPlugin(_ plugin: any ChatTurnPlugin) -> PositronicKit {
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
            chatTurnPlugins: chatTurnPlugins + [plugin],
            promptInspector: promptInspector,
            generationParameters: defaultGenerationParameters,
            toolApprovalPolicy: toolApprovalPolicy,
            sharedRegistry: promptHistoryRegistry,
            additionalStages: chatEngine.additionalStages
        )
    }

    // MARK: - Execution

    /// Vends a fresh tier-four agent runtime handle.
    public func agenticRuntime(
        timelineId: UUID,
        agentInstanceId: UUID
    ) -> AgenticRuntime {
        AgenticRuntime(
            kit: self,
            timelineId: timelineId,
            agentInstanceId: agentInstanceId
        )
    }

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
