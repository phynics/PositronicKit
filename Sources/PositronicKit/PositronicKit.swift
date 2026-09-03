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
/// protocols such as persistence stores, `WorkspaceFactory` / `WorkspaceProvider`,
/// ``RuntimeCustomization`` and the persistence/workspace protocols. Internal coordinators like `TurnEngine`,
/// `ThreadPromptHistory`, and the concrete turn pipeline remain runtime implementation details
/// even when they are visible to tests inside this package.
///
/// Example usage:
/// - Minimal: `PositronicKit(languageModel: myModel)`
/// - Production: use `PositronicKit(configuration:)`.
///
/// The public operation surface is deliberately capability-oriented: use `model` for
/// thread-free inference, `threads` for durable Thread handles, `agents` for agent
/// identity and attachment, and `workspaces` for the workspace catalog. The concrete
/// coordinators, task registries, and turn pipeline remain implementation details.
///
/// Construct once and hold for the app's lifetime. `PositronicKit` is a reference type;
/// constructing one through a regular initializer starts a new, independent cross-send history.
/// ``reconfigured(languageModel:generationParameters:)`` creates a new view over the current
/// runtime state instead.
public final class PositronicKit: Sendable {
    /// Identity-bearing process-local runtime state shared by facade views created through
    /// `reconfigured`. Provider-facing configuration remains on each view's `TurnEngine`.
    private final class RuntimeState: Sendable {
        let threadManager: ThreadManager
        let promptHistoryRegistry: ThreadPromptJournals
        let agentAuthorityCoordinator: AgentAuthorityCoordinator
        let eventHub: TurnEventHub

        init(
            threadManager: ThreadManager,
            promptHistoryRegistry: ThreadPromptJournals,
            agentAuthorityCoordinator: AgentAuthorityCoordinator,
            eventHub: TurnEventHub
        ) {
            self.threadManager = threadManager
            self.promptHistoryRegistry = promptHistoryRegistry
            self.agentAuthorityCoordinator = agentAuthorityCoordinator
            self.eventHub = eventHub
        }
    }

    // MARK: - Direct TurnEngine dependencies

    let languageModel: any LLMStreamClient

    /// Whether the injected language model currently has usable provider configuration.
    ///
    /// This reads the model's live readiness without exposing provider configuration,
    /// credentials, or mutation APIs through the facade.
    var isLanguageModelConfigured: Bool {
        get async { await languageModel.isConfigured }
    }

    // Internal so package tests can assert the facade's resolved graph without exposing stores
    // through the public capability surface.
    let messageStore: any ThreadMessageStoreProtocol
    /// Cohesive durable owner for Thread history and Turn lifecycle.
    let runtimeRepository: any ThreadRuntimeRepository
    /// Durable authority for ordinary Workspace-to-Thread bindings.
    let workspaceBindingRepository: any WorkspaceBindingRepository

    /// Internal coordinator shared by the capability values and turn engine.
    let threadManager: ThreadManager

    /// Runtime-owned identities that must survive provider reconfiguration.
    private let runtimeState: RuntimeState


    /// Internal agent coordinator shared by the capability values and turn engine.
    let agentManager: AgentManager

    /// Internal tool router wired to the facade-owned Thread coordinator.
    let toolRouter: ToolRouter

    /// Consumer-facing capability values. These keep orchestration managers behind the facade.
    public var threads: ThreadCapability { ThreadCapability(kit: self) }
    public var agents: AgentCapability { AgentCapability(kit: self) }
    public var workspaces: WorkspaceCapability { WorkspaceCapability(kit: self) }
    public var model: ModelInferenceCapability { ModelInferenceCapability(kit: self) }

    let workspaceCatalog: any WorkspaceCatalog
    private let agentStore: any AgentStoreProtocol
    // Package-internal for assembly tests; consumers use the facade capabilities instead.
    let agentAuthorityCoordinator: AgentAuthorityCoordinator
    private let requestOriginStore: any RequestOriginStoreProtocol
    private let customization: RuntimeCustomization
    private let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
    let defaultGenerationParameters: GenerationParameters?

    private let logger = Logger.module(named: "positronickit-facade")
    private let loggingConfiguration: LoggingConfiguration

    // MARK: - Transitive dependencies

    // These resolved graph nodes remain package-internal for @testable assembly coverage.
    let threadPersistence: any ThreadPersistenceProtocol
    let workspacePersistence: any WorkspaceStore
    private let toolPersistence: any ToolPersistenceProtocol

    let turnEngine: TurnEngine

    /// Owned internally; every thread driver vended by this instance shares it automatically.
    /// Construct a new `PositronicKit` for a genuinely separate cross-send history.
    private let promptHistoryRegistry: ThreadPromptJournals
    private let workspaceProfile: WorkspaceProfile
    private let workspaceCreator: any WorkspaceFactory
    private let runtimeToolPolicy: RuntimeToolPolicy
    private let degradationPolicy: TurnDegradationPolicy
    private let toolApprovalPolicy: any ToolApprovalPolicy

    // MARK: - Init

    /// Creates a provider-agnostic facade with in-memory persistence and default runtime policy.
    public convenience init(
        languageModel: any LLMStreamClient = UnconfiguredLLMService()
    ) {
        self.init(
            configuration: .init(
                provider: .init(languageModel: languageModel),
                persistence: .inMemory()
            )
        )
    }

    convenience init(
        languageModel: any LLMStreamClient,
        runtimeRepository: any ThreadRuntimeRepository,
        workspaceBindingRepository: (any WorkspaceBindingRepository)? = nil,
        agentStore: (any AgentStoreProtocol)? = nil,
        requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
        workspacePersistence: (any WorkspaceStore)? = nil,
        toolPersistence: (any ToolPersistenceProtocol)? = nil,
        workspaceProfile: WorkspaceProfile = .noWorkspace,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        customization: RuntimeCustomization = .default,
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
        degradationPolicy: TurnDegradationPolicy = .failRequired,
        generationParameters: GenerationParameters? = nil,
        toolApprovalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
        loggingConfiguration: LoggingConfiguration = .default,
        sharedRegistry: ThreadPromptJournals,
        additionalStages: [any PipelineStage<TurnContext, TurnEvent>]
    ) {
        let resolvedWorkspaceStore = workspacePersistence ?? InMemoryWorkspacePersistence()
        let resolvedBindingRepository = workspaceBindingRepository
            ?? (runtimeRepository as? any WorkspaceBindingRepository)
            ?? (resolvedWorkspaceStore as? any WorkspaceBindingRepository)
            ?? InMemoryWorkspaceBindingRepository()
        self.init(
            dependencies: KitDependencies(
                languageModel: languageModel,
                runtimeRepository: runtimeRepository,
                workspaceBindingRepository: resolvedBindingRepository,
                agentStore: agentStore ?? InMemoryAgentStore(),
                requestOriginStore: requestOriginStore ?? InMemoryRequestOriginStore(),
                workspacePersistence: resolvedWorkspaceStore,
                toolPersistence: toolPersistence ?? InMemoryToolPersistence(),
                workspaceProfile: workspaceProfile,
                workspaceCreator: workspaceCreator,
                customization: customization,
                agentAuthorityCoordinator: nil,
                runtimeToolPolicy: runtimeToolPolicy,
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
    /// wires the internal coordinators (`ThreadManager`, `AgentManager`, `ToolRouter`,
    /// `TurnEngine`) from it. The provider reconfiguration builder
    /// extract the current dependencies, mutate the single field that changes, and forward
    /// here — eliminating the repeated ~25-line parameter forwarding (PKCR-009).
    private init(dependencies: KitDependencies, runtimeState: RuntimeState? = nil) {
        languageModel = dependencies.languageModel
        runtimeRepository = dependencies.runtimeRepository
        messageStore = dependencies.runtimeRepository
        workspaceBindingRepository = dependencies.workspaceBindingRepository
        agentStore = dependencies.agentStore
        customization = dependencies.customization
        requestOriginStore = dependencies.requestOriginStore
        threadPersistence = dependencies.runtimeRepository
        workspacePersistence = dependencies.workspacePersistence
        toolPersistence = dependencies.toolPersistence
        diagnosticSnapshotConfiguration = dependencies.diagnosticSnapshotConfiguration
        degradationPolicy = dependencies.degradationPolicy
        workspaceProfile = dependencies.workspaceProfile
        workspaceCreator = dependencies.workspaceCreator
        runtimeToolPolicy = dependencies.runtimeToolPolicy
        toolApprovalPolicy = dependencies.toolApprovalPolicy
        loggingConfiguration = dependencies.loggingConfiguration
        defaultGenerationParameters = dependencies.generationParameters

        let resolvedAgentAuthorityCoordinator = runtimeState?.agentAuthorityCoordinator
            ?? dependencies.agentAuthorityCoordinator
            ?? AgentAuthorityCoordinator()
        agentAuthorityCoordinator = resolvedAgentAuthorityCoordinator

        let resolvedPromptHistoryRegistry = runtimeState?.promptHistoryRegistry
            ?? dependencies.sharedRegistry
        promptHistoryRegistry = resolvedPromptHistoryRegistry

        // The catalog root anchors agent-private workspace provisioning (a separate, opt-in
        // path from thread workspaces). For `.noWorkspace` there is no profile root, so fall
        // back to a process-temporary path so the catalog still has somewhere to anchor if a
        // host later creates agent workspaces. Thread creation itself is unaffected: `.noWorkspace`
        // provisions no thread directory regardless of this value.
        let resolvedThreadManager: ThreadManager
        let resolvedEventHub: TurnEventHub

        if let runtimeState {
            resolvedThreadManager = runtimeState.threadManager
            resolvedEventHub = runtimeState.eventHub
        } else {
            // The facade is the only place a ThreadManager gets built: every store it wraps
            // comes from the same `persistence` surface the rest of the facade uses, so there is
            // no seam where TurnEngine and ThreadManager can end up looking at different stores.
            let newThreadManager = ThreadManager(
                stores: .init(
                    threadStore: self.threadPersistence,
                    messageStore: self.messageStore,
                    workspaceStore: self.workspacePersistence,
                    workspaceBindingRepository: self.workspaceBindingRepository,
                    runtimeRepository: self.runtimeRepository,
                    toolPersistence: self.toolPersistence
                ),
                workspaceProfile: dependencies.workspaceProfile,
                workspaceCreator: dependencies.workspaceCreator,
                runtimeToolPolicy: dependencies.runtimeToolPolicy,
                promptHistoryRegistry: resolvedPromptHistoryRegistry
            )
            resolvedThreadManager = newThreadManager
            resolvedEventHub = TurnEventHub()
        }

        let resolvedCatalogRoot = dependencies.workspaceProfile.catalogRoot
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        let resolvedWorkspaceCatalog = DefaultWorkspaceCatalog(
            workspaceRoot: resolvedCatalogRoot,
            workspacePersistence: self.workspacePersistence,
            bindingRepository: self.workspaceBindingRepository,
            runtimeRepository: self.runtimeRepository,
            threadAuthorityCoordinator: resolvedThreadManager.threadAuthorityCoordinator
        )
        let resolvedAgentManager = AgentManager(
            repository: resolvedWorkspaceCatalog,
            stores: .init(
                agentStore: self.agentStore,
                threadStore: self.threadPersistence,
                messageStore: self.messageStore,
                workspaceStore: self.workspacePersistence,
                runtimeRepository: self.runtimeRepository,
                threadAuthorityCoordinator: resolvedThreadManager.threadAuthorityCoordinator,
                agentAuthorityCoordinator: resolvedAgentAuthorityCoordinator
            ),
            threadManager: resolvedThreadManager
        )
        let resolvedToolRouter = ToolRouter(
            threadManager: resolvedThreadManager,
            runtimeRepository: self.runtimeRepository,
            approvalPolicy: dependencies.toolApprovalPolicy,
            loggingConfiguration: dependencies.loggingConfiguration
        )

        let resolvedRuntimeState = runtimeState ?? RuntimeState(
            threadManager: resolvedThreadManager,
            promptHistoryRegistry: resolvedPromptHistoryRegistry,
            agentAuthorityCoordinator: resolvedAgentAuthorityCoordinator,
            eventHub: resolvedEventHub
        )
        self.runtimeState = resolvedRuntimeState
        threadManager = resolvedRuntimeState.threadManager
        workspaceCatalog = resolvedWorkspaceCatalog
        agentManager = resolvedAgentManager
        toolRouter = resolvedToolRouter

        var activitySinks: [any AgentActivitySink] = []
        if let hostActivitySink = self.customization.agentActivitySink {
            activitySinks.append(hostActivitySink)
        }
        let resolvedActivitySink: (any AgentActivitySink)? = activitySinks.isEmpty
            ? nil
            : AgentActivityFanout(sinks: activitySinks)

        var engine = TurnEngine(
            dependencies: .init(
                threadManager: resolvedThreadManager,
                agentStore: self.agentStore,
                agentContextSource: self.customization.agentContextSource ?? DefaultAgentContextSource(
                    workspaceStore: dependencies.workspacePersistence
                ),
                requestOriginStore: self.requestOriginStore,
                runtimeRepository: self.runtimeRepository,
                threadAuthorityCoordinator: resolvedThreadManager.threadAuthorityCoordinator,
                agentAuthorityCoordinator: self.agentAuthorityCoordinator,
                llmService: self.languageModel,
                toolRouter: toolRouter,
                turnContextSource: self.customization.turnContextSource,
                agentActivitySink: resolvedActivitySink,
                turnOutcomeSink: self.customization.turnOutcomeSink,
                diagnosticSnapshotConfiguration: dependencies.diagnosticSnapshotConfiguration,
                loggingConfiguration: dependencies.loggingConfiguration,
                degradationPolicy: dependencies.degradationPolicy,
                promptHistoryRegistry: promptHistoryRegistry,
                eventHub: resolvedEventHub
            )
        )
        engine.additionalStages = dependencies.additionalStages
        turnEngine = engine
    }

    /// Snapshots the facade's current resolved dependencies into a ``KitDependencies`` value
    /// so builder methods can copy, mutate a single field, and forward to
    /// ``init(dependencies:)`` without repeating the full parameter list.
    var dependencies: KitDependencies {
        KitDependencies(
            languageModel: languageModel,
            runtimeRepository: runtimeRepository,
            workspaceBindingRepository: workspaceBindingRepository,
            agentStore: agentStore,
            requestOriginStore: requestOriginStore,
            workspacePersistence: workspacePersistence,
            toolPersistence: toolPersistence,
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            customization: customization,
            agentAuthorityCoordinator: agentAuthorityCoordinator,
            runtimeToolPolicy: runtimeToolPolicy,
            diagnosticSnapshotConfiguration: diagnosticSnapshotConfiguration,
            degradationPolicy: degradationPolicy,
            generationParameters: defaultGenerationParameters,
            toolApprovalPolicy: toolApprovalPolicy,
            loggingConfiguration: loggingConfiguration,
            sharedRegistry: promptHistoryRegistry,
            additionalStages: turnEngine.additionalStages
        )
    }

    /// Returns a new facade with updated provider/generation configuration while preserving the
    /// current instance's runtime-owned cross-send state (prompt-history journal diffs and
    /// inspection turn indexing), stores, tools, plugins, and workspace wiring.
    ///
    /// This is the supported path for hosts that must refresh provider settings between sends
    /// without silently resetting per-thread prompt-history state.
    public func reconfigured(
        languageModel: any LLMStreamClient,
        generationParameters: GenerationParameters? = nil
    ) -> PositronicKit {
        var deps = dependencies
        deps.languageModel = languageModel
        deps.generationParameters = generationParameters ?? defaultGenerationParameters
        return PositronicKit(dependencies: deps, runtimeState: runtimeState)
    }

    // MARK: - Builder

    /// Adds a custom stage to the chat execution pipeline.
    /// - Parameter stage: The custom pipeline stage to add.
    /// - Returns: A new instance with the stage added.
    ///
    /// This remains package-internal and is reserved for runtime-owned verification stages; it is
    /// not a consumer customization surface.
    func addingStage(_ stage: any PipelineStage<TurnContext, TurnEvent>) -> PositronicKit {
        var deps = dependencies
        deps.additionalStages += [stage]
        return PositronicKit(dependencies: deps, runtimeState: runtimeState)
    }

    // MARK: - Execution

    func startTurnHandle(
        _ request: TurnRequest,
        agentID: UUID?,
        executionKind: TurnExecutionKind,
        contributors: [TurnContributor] = []
    ) async throws -> TurnHandle {
        let executionRequest = TurnExecutionRequest(
            request,
            defaultGenerationParameters: defaultGenerationParameters,
            agentID: agentID,
            executionKind: executionKind,
            contributors: contributors
        )
        let execution = try await turnEngine.startExecution(executionRequest)
        return TurnHandle(
            id: execution.turnID,
            threadID: request.threadID,
            eventStream: nonThrowingEvents(from: execution.stream),
            kit: self
        )
    }

    private func nonThrowingEvents(
        from source: AsyncThrowingStream<TurnEvent, Error>
    ) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            Task {
                var terminalDelivered = false
                do {
                    for try await event in source {
                        if event.isTerminal {
                            if terminalDelivered { continue }
                            terminalDelivered = true
                        }
                        continuation.yield(event)
                    }
                } catch {
                    if !terminalDelivered {
                        continuation.yield(.error(error))
                    }
                }
                continuation.finish()
            }
        }
    }

    func waitForTurnOutcome(id turnID: UUID) async -> TurnOutcome {
        while !Task.isCancelled {
            if let record = try? await runtimeRepository.fetchTurn(id: turnID),
               let outcome = record.outcome
            {
                return outcome
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return .cancelled(reason: "Outcome wait cancelled.")
    }

    func cancelTurn(id turnID: UUID, threadID: UUID) async {
        _ = await threadManager.cancelGeneration(turnID: turnID, for: threadID)
    }

    /// Run a turn and return a stream of events.
    /// - Parameter request: The full turn configuration.
    /// - Returns: An asynchronous stream of turn events.
    func run(
        _ request: TurnRequest,
        agentID: UUID? = nil,
        executionKind: TurnExecutionKind = .direct,
        contributors: [TurnContributor] = []
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        let executionRequest = TurnExecutionRequest(
            request,
            defaultGenerationParameters: defaultGenerationParameters,
            agentID: agentID,
            executionKind: executionKind,
            contributors: contributors
        )
        return try await turnEngine.execute(executionRequest)
    }

}
