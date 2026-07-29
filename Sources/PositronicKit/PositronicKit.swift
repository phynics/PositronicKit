import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

/// The public facade for PositronicKit's agent runtime subsystem.
///
/// Accepts all required services as init parameters and wires them internally,
/// so consumers never need to assemble a shared dependency container.
///
/// Only `languageModel` is required. All other parameters have sensible in-memory defaults
/// suitable for development and prototyping. For production, provide persistent stores.
///
/// PositronicKit intentionally stays transport-neutral. Concepts like timelines, workspaces,
/// agents, tool routing, and prompt assembly live here; concrete networking or multi-process hosting models are
/// expected to be provided downstream via injected stores, workspace creators, and connection hooks.
///
/// Intended extension seams for downstream applications are the facade itself plus public runtime
/// protocols such as persistence stores, `WorkspaceFactory` / `Workspace`,
/// `PromptSectionProviding`, and `ChatTurnPlugin`. Internal coordinators like `ChatEngine`,
/// `TimelinePromptHistory`, and the concrete turn pipeline remain runtime implementation details
/// even when they are visible to tests inside this package.
///
/// Example usage:
/// - Minimal: `PositronicKit(languageModel: myModel)`
/// - Production: use `PositronicKit(configuration:)`.
///
/// The public operation ladder is progressive: tier 1 is timeline-free one-shot
/// `complete(_:)`/`stream(_:)`; tier 2 is the stateful `TimelineDriver`; tier 3 is
/// direct `timelineManager` access; tier 4 is the full `AgenticRuntime` tool/agent loop;
/// tier 5 is the raw primitives (`toolRouter`, `languageModel`, and the prompt DSL) for a
/// bespoke pipeline. A typical application wraps one kit in an application-owned Service
/// class, then passes the managers or controllers it vends to the relevant subsystems.
///
/// Construct once and hold for the app's lifetime. `PositronicKit` is a reference type;
/// constructing a new instance starts a new, independent cross-send history.
public final class PositronicKit: Sendable {
    // MARK: - Direct ChatEngine dependencies

    let languageModel: any LanguageModel

    @available(*, deprecated, renamed: "languageModel")
    var llmService: any LanguageModel { languageModel }
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
    private let promptObserver: (any PromptObserving)?
    private let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
    let defaultGenerationParameters: GenerationParameters?
    private let logger = Logger.module(named: "positronickit-facade")
    private let loggingConfiguration: LoggingConfiguration

    // MARK: - Transitive dependencies (TimelineManager, TurnBriefingBuilder)

    private let timelinePersistence: any TimelinePersistenceProtocol
    private let workspacePersistence: any WorkspaceStore
    private let memoryStore: any MemoryStoreProtocol
    private let toolPersistence: any ToolPersistenceProtocol
    private let embeddingService: any EmbeddingServiceProtocol

    private let chatEngine: ChatEngine

    /// Owned internally; every timeline driver vended by this instance shares it automatically.
    /// Construct a new `PositronicKit` for a genuinely separate cross-send history.
    private let promptHistoryRegistry: TimelinePromptJournals
    private let workspaceProfile: WorkspaceProfile
    private let workspaceCreator: any WorkspaceFactory
    private let sectionProviders: [any PromptSectionProviding]
    private let runtimeToolPolicy: TimelineManager.RuntimeToolPolicy
    private let degradationPolicy: TurnDegradationPolicy
    private let toolApprovalPolicy: any ToolApprovalPolicy

    // MARK: - Init

    /// Creates a provider-agnostic facade with in-memory persistence and default runtime policy.
    public convenience init(
        languageModel: any LanguageModel = UnconfiguredLLMService()
    ) {
        self.init(
            configuration: .init(
                provider: .init(languageModel: languageModel),
                persistence: .inMemory()
            )
        )
    }

    @available(*, deprecated, renamed: "init(languageModel:)")
    public convenience init(
        llmService: any LanguageModel
    ) {
        self.init(languageModel: llmService)
    }

    @available(*, deprecated, renamed: "init(languageModel:generationParameters:)")
    public func reconfigured(
        llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient,
        generationParameters: GenerationParameters? = nil
    ) -> PositronicKit {
        reconfigured(languageModel: AnyLanguageModel(base: llmService), generationParameters: generationParameters)
    }

    init(
        languageModel: any LanguageModel,
        messageStore: (any MessageStoreProtocol)? = nil,
        agentInstanceStore: (any AgentInstanceStoreProtocol)? = nil,
        requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
        timelinePersistence: (any TimelinePersistenceProtocol)? = nil,
        workspacePersistence: (any WorkspaceStore)? = nil,
        memoryStore: (any MemoryStoreProtocol)? = nil,
        toolPersistence: (any ToolPersistenceProtocol)? = nil,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        workspaceProfile: WorkspaceProfile = .noWorkspace,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: TimelineManager.RuntimeToolPolicy = .default,
        chatTurnPlugins: [any ChatTurnPlugin] = [],
        promptObserver: (any PromptObserving)? = nil,
        diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
        degradationPolicy: TurnDegradationPolicy = .failRequired,
        generationParameters: GenerationParameters? = nil,
        toolApprovalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
        loggingConfiguration: LoggingConfiguration = .default,
        sharedRegistry: TimelinePromptJournals,
        additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>]
    ) {
        self.languageModel = languageModel
        self.messageStore = messageStore ?? InMemoryMessageStore()
        self.agentInstanceStore = agentInstanceStore ?? InMemoryAgentInstanceStore()
        self.requestOriginStore = requestOriginStore ?? InMemoryRequestOriginStore()
        self.timelinePersistence = timelinePersistence ?? InMemoryTimelinePersistence()
        self.workspacePersistence = workspacePersistence ?? InMemoryWorkspacePersistence()
        self.memoryStore = memoryStore ?? InMemoryMemoryStore()
        self.toolPersistence = toolPersistence ?? InMemoryToolPersistence()
        self.embeddingService = embeddingService ?? NoOpEmbeddingService()
        self.chatTurnPlugins = chatTurnPlugins
        self.promptObserver = promptObserver
        self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
        self.degradationPolicy = degradationPolicy
        promptHistoryRegistry = sharedRegistry
        self.workspaceProfile = workspaceProfile
        self.workspaceCreator = workspaceCreator
        self.sectionProviders = sectionProviders
        self.runtimeToolPolicy = runtimeToolPolicy
        self.toolApprovalPolicy = toolApprovalPolicy
        self.loggingConfiguration = loggingConfiguration
        defaultGenerationParameters = generationParameters

        // The catalog root anchors agent-private workspace provisioning (a separate, opt-in
        // path from timeline workspaces). For `.noWorkspace` there is no profile root, so fall
        // back to a process-temporary path so the catalog still has somewhere to anchor if a
        // host later creates agent workspaces. Timeline creation itself is unaffected: `.noWorkspace`
        // provisions no timeline directory regardless of this value.
        let resolvedCatalogRoot = workspaceProfile.catalogRoot
            ?? FileManager.default.temporaryDirectory
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
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: self.embeddingService,
            promptHistoryRegistry: promptHistoryRegistry
        )
        timelineManager = resolvedTimelineManager
        agentInstanceManager = AgentInstanceManager(
            repository: DefaultWorkspaceCatalog(
                workspaceRoot: resolvedCatalogRoot,
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
            approvalPolicy: toolApprovalPolicy,
            loggingConfiguration: loggingConfiguration
        )
        var engine = ChatEngine(
            dependencies: .init(
                timelineManager: resolvedTimelineManager,
                agentInstanceStore: self.agentInstanceStore,
                requestOriginStore: self.requestOriginStore,
                messageStore: self.messageStore,
                llmService: self.languageModel,
                toolRouter: toolRouter,
                chatTurnPlugins: self.chatTurnPlugins,
                promptObserver: self.promptObserver,
                diagnosticSnapshotConfiguration: diagnosticSnapshotConfiguration,
                loggingConfiguration: loggingConfiguration,
                degradationPolicy: degradationPolicy,
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
        languageModel: any LanguageModel,
        generationParameters: GenerationParameters? = nil
    ) -> PositronicKit {
        PositronicKit(
            languageModel: languageModel,
            messageStore: messageStore,
            agentInstanceStore: agentInstanceStore,
            requestOriginStore: requestOriginStore,
            timelinePersistence: timelinePersistence,
            workspacePersistence: workspacePersistence,
            memoryStore: memoryStore,
            toolPersistence: toolPersistence,
            embeddingService: embeddingService,
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            chatTurnPlugins: chatTurnPlugins,
            promptObserver: promptObserver,
            diagnosticSnapshotConfiguration: diagnosticSnapshotConfiguration,
            degradationPolicy: degradationPolicy,
            generationParameters: generationParameters ?? defaultGenerationParameters,
            toolApprovalPolicy: toolApprovalPolicy,
            loggingConfiguration: loggingConfiguration,
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
            languageModel: languageModel,
            messageStore: messageStore,
            agentInstanceStore: agentInstanceStore,
            requestOriginStore: requestOriginStore,
            timelinePersistence: timelinePersistence,
            workspacePersistence: workspacePersistence,
            memoryStore: memoryStore,
            toolPersistence: toolPersistence,
            embeddingService: embeddingService,
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            chatTurnPlugins: chatTurnPlugins,
            promptObserver: promptObserver,
            diagnosticSnapshotConfiguration: diagnosticSnapshotConfiguration,
            generationParameters: defaultGenerationParameters,
            toolApprovalPolicy: toolApprovalPolicy,
            loggingConfiguration: loggingConfiguration,
            sharedRegistry: promptHistoryRegistry,
            additionalStages: chatEngine.additionalStages + [stage]
        )
    }

    /// Adds a chat turn plugin that runs after each LLM turn.
    /// - Parameter plugin: The plugin to add.
    /// - Returns: A new instance with the plugin added.
    public func addingPlugin(_ plugin: any ChatTurnPlugin) -> PositronicKit {
        PositronicKit(
            languageModel: languageModel,
            messageStore: messageStore,
            agentInstanceStore: agentInstanceStore,
            requestOriginStore: requestOriginStore,
            timelinePersistence: timelinePersistence,
            workspacePersistence: workspacePersistence,
            memoryStore: memoryStore,
            toolPersistence: toolPersistence,
            embeddingService: embeddingService,
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            chatTurnPlugins: chatTurnPlugins + [plugin],
            promptObserver: promptObserver,
            diagnosticSnapshotConfiguration: diagnosticSnapshotConfiguration,
            generationParameters: defaultGenerationParameters,
            toolApprovalPolicy: toolApprovalPolicy,
            loggingConfiguration: loggingConfiguration,
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
        let resolvedTurnBriefingBuilder = try await resolveTurnBriefingBuilder(
            explicit: nil,
            timelineId: request.timelineId
        )

        return try await chatEngine.execute(
            timelineId: request.timelineId,
            sendId: request.sendId,
            message: request.message,
            tools: request.tools,
            toolOutputs: request.toolOutputs,
            turnBriefingBuilder: resolvedTurnBriefingBuilder,
            systemInstructions: request.systemInstructions,
            agentInstanceId: request.agentInstanceId,
            maxTurns: request.maxTurns,
            generationParameters: request.generationParameters ?? defaultGenerationParameters,
            structuredOutput: request.structuredOutput,
            sidecars: request.sidecars,
            sidecarCommitPolicy: request.sidecarCommitPolicy,
            includeSidecarMechanismPreamble: request.includeSidecarMechanismPreamble,
            assemblyLogger: request.promptAssemblyLogger
        )
    }

    /// Resolves the `TurnBriefingBuilder` for a turn, hydrating the timeline from persistence
    /// first if it isn't already cached in memory.
    ///
    /// Hydration failure propagates as a typed ``TimelineError``: `.timelineNotFound` for a
    /// missing ID, `.unavailable` for a transient store fault. The error reaches the caller
    /// before input persistence runs (PKRR-006), so no user input is persisted under an
    /// unestablished timeline.
    private func resolveTurnBriefingBuilder(
        explicit turnBriefingBuilder: TurnBriefingBuilder?,
        timelineId: UUID
    ) async throws -> TurnBriefingBuilder? {
        if let turnBriefingBuilder {
            return turnBriefingBuilder
        }

        if let existing = await timelineManager.getTurnBriefingBuilder(for: timelineId) {
            return existing
        }

        try await timelineManager.ensureTimelineExists(id: timelineId)
        return await timelineManager.getTurnBriefingBuilder(for: timelineId)
    }
}
