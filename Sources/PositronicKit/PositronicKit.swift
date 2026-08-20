import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// The public facade for PositronicKit's agent runtime subsystem.
///
/// Accepts all required services as init parameters and wires them internally,
/// so consumers never need to assemble a shared dependency container.
///
/// Only `languageModel` is required. All other parameters have sensible in-memory defaults
/// suitable for development and prototyping. For production, provide persistent stores.
///
/// PositronicKit intentionally stays transport-neutral. Concepts like threads, workspaces,
/// agents, tool routing, and prompt assembly live here; concrete networking or multi-process hosting models are
/// expected to be provided downstream via injected stores, workspace creators, and connection hooks.
///
/// Intended extension seams for downstream applications are the facade itself plus public runtime
/// protocols such as persistence stores, `WorkspaceFactory` / `Workspace`,
/// `PromptSectionProviding`, and `ChatTurnPlugin`. Internal coordinators like `ChatEngine`,
/// `ThreadPromptHistory`, and the concrete turn pipeline remain runtime implementation details
/// even when they are visible to tests inside this package.
///
/// Example usage:
/// - Minimal: `PositronicKit(languageModel: myModel)`
/// - Production: use `PositronicKit(configuration:)`.
///
/// The public operation ladder is progressive: tier 1 is thread-free one-shot
/// `complete(_:)`/`stream(_:)`; tier 2 is the stateful `ThreadDriver`; tier 3 is
/// direct `threadManager` access; tier 4 is the full `AgenticRuntime` tool/agent loop;
/// tier 5 is the raw primitives (`toolRouter`, `languageModel`, and the prompt DSL) for a
/// bespoke pipeline. A typical application wraps one kit in an application-owned Service
/// class, then passes the managers or controllers it vends to the relevant subsystems.
///
/// Construct once and hold for the app's lifetime. `PositronicKit` is a reference type;
/// constructing a new instance starts a new, independent cross-send history.
public final class PositronicKit: Sendable {
    // MARK: - Direct ChatEngine dependencies

    let languageModel: any LLMStreamClient & LLMUtilityClient

    /// Whether the injected language model currently has usable provider configuration.
    ///
    /// This reads the model's live readiness without exposing provider configuration,
    /// credentials, or mutation APIs through the facade.
    public var isLanguageModelConfigured: Bool {
        get async { await languageModel.isConfigured }
    }

    private let messageStore: any ThreadMessageStoreProtocol

    /// The thread manager built by this facade. Hosts that need direct access (e.g. to wire
    /// their own routes) should read this instead of building a second `ThreadManager`, which
    /// would silently diverge from the stores the facade itself uses.
    public let threadManager: ThreadManager


    /// The single agent-instance manager owned by this facade. It is wired to the same
    /// thread manager and persistence stores as the rest of the runtime.
    public let agentInstanceManager: AgentInstanceManager

    /// The tool router built by this facade, wired to `threadManager` above.
    public let toolRouter: ToolRouter
    private let agentInstanceStore: any AgentInstanceStoreProtocol
    private let requestOriginStore: any RequestOriginStoreProtocol
    private let chatTurnPlugins: [any ChatTurnPlugin]
    private let promptObserver: (any PromptObserving)?
    private let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
    let defaultGenerationParameters: GenerationParameters?
    private let logger = Logger.module(named: "positronickit-facade")
    private let loggingConfiguration: LoggingConfiguration

    // MARK: - Transitive dependencies (ThreadManager, TurnBriefingBuilder)

    private let threadPersistence: any ThreadPersistenceProtocol
    private let workspacePersistence: any WorkspaceStore
    private let memoryStore: any MemoryStoreProtocol
    private let toolPersistence: any ToolPersistenceProtocol
    private let embeddingService: any EmbeddingServiceProtocol

    private let chatEngine: ChatEngine

    /// Owned internally; every thread driver vended by this instance shares it automatically.
    /// Construct a new `PositronicKit` for a genuinely separate cross-send history.
    private let promptHistoryRegistry: ThreadPromptJournals
    private let workspaceProfile: WorkspaceProfile
    private let workspaceCreator: any WorkspaceFactory
    private let sectionProviders: [any PromptSectionProviding]
    private let runtimeToolPolicy: ThreadManager.RuntimeToolPolicy
    private let degradationPolicy: TurnDegradationPolicy
    private let toolApprovalPolicy: any ToolApprovalPolicy

    // MARK: - Init

    /// Creates a provider-agnostic facade with in-memory persistence and default runtime policy.
    public convenience init(
        languageModel: any LLMStreamClient & LLMUtilityClient = UnconfiguredLLMService()
    ) {
        self.init(
            configuration: .init(
                provider: .init(languageModel: languageModel),
                persistence: .inMemory()
            )
        )
    }

    convenience init(
        languageModel: any LLMStreamClient & LLMUtilityClient,
        messageStore: (any ThreadMessageStoreProtocol)? = nil,
        agentInstanceStore: (any AgentInstanceStoreProtocol)? = nil,
        requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
        threadPersistence: (any ThreadPersistenceProtocol)? = nil,
        workspacePersistence: (any WorkspaceStore)? = nil,
        memoryStore: (any MemoryStoreProtocol)? = nil,
        toolPersistence: (any ToolPersistenceProtocol)? = nil,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        workspaceProfile: WorkspaceProfile = .noWorkspace,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: ThreadManager.RuntimeToolPolicy = .default,
        chatTurnPlugins: [any ChatTurnPlugin] = [],
        promptObserver: (any PromptObserving)? = nil,
        diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
        degradationPolicy: TurnDegradationPolicy = .failRequired,
        generationParameters: GenerationParameters? = nil,
        toolApprovalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
        loggingConfiguration: LoggingConfiguration = .default,
        sharedRegistry: ThreadPromptJournals,
        additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>]
    ) {
        self.init(
            dependencies: KitDependencies(
                languageModel: languageModel,
                messageStore: messageStore ?? InMemoryMessageStore(),
                agentInstanceStore: agentInstanceStore ?? InMemoryAgentInstanceStore(),
                requestOriginStore: requestOriginStore ?? InMemoryRequestOriginStore(),
                threadPersistence: threadPersistence ?? InMemoryThreadPersistence(),
                workspacePersistence: workspacePersistence ?? InMemoryWorkspacePersistence(),
                memoryStore: memoryStore ?? InMemoryMemoryStore(),
                toolPersistence: toolPersistence ?? InMemoryToolPersistence(),
                embeddingService: embeddingService ?? NoOpEmbeddingService(),
                workspaceProfile: workspaceProfile,
                workspaceCreator: workspaceCreator,
                sectionProviders: sectionProviders,
                runtimeToolPolicy: runtimeToolPolicy,
                chatTurnPlugins: chatTurnPlugins,
                promptObserver: promptObserver,
                diagnosticSnapshotConfiguration: diagnosticSnapshotConfiguration,
                degradationPolicy: degradationPolicy,
                generationParameters: generationParameters,
                toolApprovalPolicy: toolApprovalPolicy,
                loggingConfiguration: loggingConfiguration,
                sharedRegistry: sharedRegistry,
                additionalStages: additionalStages
            )
        )
    }

    /// The designated initializer. Accepts a fully-resolved ``KitDependencies`` bundle and
    /// wires the internal coordinators (`ThreadManager`, `AgentInstanceManager`, `ToolRouter`,
    /// `ChatEngine`) from it. Builder methods (`reconfigured`, `addingStage`, `addingPlugin`)
    /// extract the current dependencies, mutate the single field that changes, and forward
    /// here — eliminating the repeated ~25-line parameter forwarding (PKCR-009).
    init(dependencies: KitDependencies) {
        languageModel = dependencies.languageModel
        messageStore = dependencies.messageStore
        agentInstanceStore = dependencies.agentInstanceStore
        requestOriginStore = dependencies.requestOriginStore
        threadPersistence = dependencies.threadPersistence
        workspacePersistence = dependencies.workspacePersistence
        memoryStore = dependencies.memoryStore
        toolPersistence = dependencies.toolPersistence
        embeddingService = dependencies.embeddingService
        chatTurnPlugins = dependencies.chatTurnPlugins
        promptObserver = dependencies.promptObserver
        diagnosticSnapshotConfiguration = dependencies.diagnosticSnapshotConfiguration
        degradationPolicy = dependencies.degradationPolicy
        promptHistoryRegistry = dependencies.sharedRegistry
        workspaceProfile = dependencies.workspaceProfile
        workspaceCreator = dependencies.workspaceCreator
        sectionProviders = dependencies.sectionProviders
        runtimeToolPolicy = dependencies.runtimeToolPolicy
        toolApprovalPolicy = dependencies.toolApprovalPolicy
        loggingConfiguration = dependencies.loggingConfiguration
        defaultGenerationParameters = dependencies.generationParameters

        // The catalog root anchors agent-private workspace provisioning (a separate, opt-in
        // path from thread workspaces). For `.noWorkspace` there is no profile root, so fall
        // back to a process-temporary path so the catalog still has somewhere to anchor if a
        // host later creates agent workspaces. Thread creation itself is unaffected: `.noWorkspace`
        // provisions no thread directory regardless of this value.
        let resolvedCatalogRoot = dependencies.workspaceProfile.catalogRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        // The facade is the only place a ThreadManager gets built: every store it wraps
        // comes from the same `persistence` surface the rest of the facade uses, so there is
        // no seam where ChatEngine and ThreadManager can end up looking at different stores.
        let resolvedThreadManager = ThreadManager(
            stores: .init(
                threadStore: self.threadPersistence,
                messageStore: self.messageStore,
                workspaceStore: self.workspacePersistence,
                toolPersistence: self.toolPersistence,
                memoryStore: self.memoryStore
            ),
            workspaceProfile: dependencies.workspaceProfile,
            workspaceCreator: dependencies.workspaceCreator,
            sectionProviders: dependencies.sectionProviders,
            runtimeToolPolicy: dependencies.runtimeToolPolicy,
            embeddingService: self.embeddingService,
            promptHistoryRegistry: promptHistoryRegistry
        )
        threadManager = resolvedThreadManager
        agentInstanceManager = AgentInstanceManager(
            repository: DefaultWorkspaceCatalog(
                workspaceRoot: resolvedCatalogRoot,
                workspacePersistence: self.workspacePersistence
            ),
            stores: .init(
                instanceStore: self.agentInstanceStore,
                threadStore: self.threadPersistence,
                messageStore: self.messageStore,
                workspaceStore: self.workspacePersistence
            ),
            threadManager: resolvedThreadManager
        )
        toolRouter = ToolRouter(
            threadManager: resolvedThreadManager,
            messageStore: self.messageStore,
            approvalPolicy: dependencies.toolApprovalPolicy,
            loggingConfiguration: dependencies.loggingConfiguration
        )
        var engine = ChatEngine(
            dependencies: .init(
                threadManager: resolvedThreadManager,
                agentInstanceStore: self.agentInstanceStore,
                requestOriginStore: self.requestOriginStore,
                messageStore: self.messageStore,
                llmService: self.languageModel,
                toolRouter: toolRouter,
                chatTurnPlugins: self.chatTurnPlugins,
                promptObserver: self.promptObserver,
                diagnosticSnapshotConfiguration: dependencies.diagnosticSnapshotConfiguration,
                loggingConfiguration: dependencies.loggingConfiguration,
                degradationPolicy: dependencies.degradationPolicy,
                promptHistoryRegistry: promptHistoryRegistry
            )
        )
        engine.additionalStages = dependencies.additionalStages
        chatEngine = engine
    }

    /// Snapshots the facade's current resolved dependencies into a ``KitDependencies`` value
    /// so builder methods can copy, mutate a single field, and forward to
    /// ``init(dependencies:)`` without repeating the full parameter list.
    var dependencies: KitDependencies {
        KitDependencies(
            languageModel: languageModel,
            messageStore: messageStore,
            agentInstanceStore: agentInstanceStore,
            requestOriginStore: requestOriginStore,
            threadPersistence: threadPersistence,
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
            generationParameters: defaultGenerationParameters,
            toolApprovalPolicy: toolApprovalPolicy,
            loggingConfiguration: loggingConfiguration,
            sharedRegistry: promptHistoryRegistry,
            additionalStages: chatEngine.additionalStages
        )
    }

    /// Returns a new facade with updated provider/generation configuration while preserving the
    /// current instance's runtime-owned cross-send state (prompt-history journal diffs and
    /// inspection turn indexing), stores, tools, plugins, and workspace wiring.
    ///
    /// This is the supported path for hosts that must refresh provider settings between sends
    /// without silently resetting per-thread prompt-history state.
    public func reconfigured(
        languageModel: any LLMStreamClient & LLMUtilityClient,
        generationParameters: GenerationParameters? = nil
    ) -> PositronicKit {
        var deps = dependencies
        deps.languageModel = languageModel
        deps.generationParameters = generationParameters ?? defaultGenerationParameters
        return PositronicKit(dependencies: deps)
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
        var deps = dependencies
        deps.additionalStages += [stage]
        return PositronicKit(dependencies: deps)
    }

    /// Adds a chat turn plugin that runs after each LLM turn.
    /// - Parameter plugin: The plugin to add.
    /// - Returns: A new instance with the plugin added.
    public func addingPlugin(_ plugin: any ChatTurnPlugin) -> PositronicKit {
        var deps = dependencies
        deps.chatTurnPlugins += [plugin]
        return PositronicKit(dependencies: deps)
    }

    // MARK: - Execution

    /// Vends a fresh tier-four agent runtime handle.
    public func agenticRuntime(
        threadID: UUID,
        agentInstanceID: UUID? = nil
    ) -> AgenticRuntime {
        AgenticRuntime(
            kit: self,
            threadID: threadID,
            agentInstanceID: agentInstanceID
        )
    }

    /// Run a chat turn and return a stream of events.
    /// - Parameter request: The full turn configuration.
    /// - Returns: An asynchronous stream of chat events.
    public func run(_ request: ChatRunRequest) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        guard request.maxTurns >= 1 else {
            throw ChatRunError.invalidMaxTurns(request.maxTurns)
        }

        let resolvedTurnBriefingBuilder = try await resolveTurnBriefingBuilder(
            explicit: nil,
            threadID: request.threadID
        )

        return try await chatEngine.execute(
            threadID: request.threadID,
            sendId: request.sendID,
            messageContent: request.messageContent,
            tools: request.tools,
            toolOutputs: request.toolOutputs,
            turnBriefingBuilder: resolvedTurnBriefingBuilder,
            systemInstructions: request.systemInstructions,
            agentInstanceId: request.agentInstanceID,
            maxTurns: request.maxTurns,
            generationParameters: request.generationParameters ?? defaultGenerationParameters,
            structuredOutput: request.structuredOutput,
            sidecars: request.sidecars,
            sidecarCommitPolicy: request.sidecarCommitPolicy,
            includeSidecarMechanismPreamble: request.includeSidecarMechanismPreamble,
            assemblyLogger: request.promptAssemblyLogger,
            responseModalities: request.responseModalities,
            audioOutput: request.audioOutput
        )
    }

    /// Resolves the `TurnBriefingBuilder` for a turn, hydrating the thread from persistence
    /// first if it isn't already cached in memory.
    ///
    /// Hydration failure propagates as a typed ``ThreadError``: `.threadNotFound` for a
    /// missing ID, `.unavailable` for a transient store fault. The error reaches the caller
    /// before input persistence runs (PKRR-006), so no user input is persisted under an
    /// unestablished thread.
    private func resolveTurnBriefingBuilder(
        explicit turnBriefingBuilder: TurnBriefingBuilder?,
        threadID: UUID
    ) async throws -> TurnBriefingBuilder? {
        if let turnBriefingBuilder {
            return turnBriefingBuilder
        }

        if let existing = await threadManager.getTurnBriefingBuilder(for: threadID) {
            return existing
        }

        try await threadManager.ensureThreadExists(id: threadID)
        return await threadManager.getTurnBriefingBuilder(for: threadID)
    }
}
