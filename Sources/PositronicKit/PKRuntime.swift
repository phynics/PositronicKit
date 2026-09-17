import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities
import Synchronization

/// The public facade for PositronicKit's agent runtime subsystem.
///
/// Accepts all required services as init parameters and wires them internally,
/// so consumers never need to assemble a shared dependency container.
///
/// Only `languageModel` is required. All other parameters have sensible in-memory defaults
/// suitable for development and prototyping. For production, provide persistent stores.
///
/// PKRuntime intentionally stays transport-neutral. Concepts like timelines, workspaces,
/// agents, tool routing, and prompt assembly live here; concrete networking or multi-process hosting models are
/// expected to be provided downstream via injected stores, workspace creators, and connection hooks.
///
/// Intended extension seams for downstream applications are the facade itself plus public runtime
/// protocols such as persistence stores, `WorkspaceFactory` / `WorkspaceProvider`,
/// ``RuntimeCustomization`` and the persistence/workspace protocols. Internal coordinators like `TurnEngine`,
/// `TimelinePromptHistory`, and the concrete turn pipeline remain runtime implementation details
/// even when they are visible to tests inside this package.
///
/// Example usage:
/// - Minimal: `PKRuntime(languageModel: myModel)`
/// - Production: use `PKRuntime(configuration:)`.
///
/// The public operation surface is deliberately capability-oriented: use `model` for
/// timeline-free inference, `timelines` for durable Timeline handles, `agents` for agent
/// identity and attachment, and `workspaces` for the workspace catalog. The concrete
/// coordinators, task registries, and turn pipeline remain implementation details.
///
/// Construct once and hold for the app's lifetime. `PKRuntime` is a reference type;
/// constructing one through a regular initializer starts a new, independent cross-send history.
/// ``reconfigured(languageModel:generationParameters:)`` creates a new view over the current
/// runtime state instead.
public final class PKRuntime: Sendable {
    /// Identity-bearing process-local runtime state shared by facade views created through
    /// `reconfigured`. Provider-facing configuration remains on each view's `TurnEngine`.
    private final class RuntimeState: Sendable {
        let timelineManager: TimelineManager
        let promptHistoryRegistry: TimelinePromptJournals
        let agentAuthorityCoordinator: AgentAuthorityCoordinator
        let eventHub: TurnEventHub
        /// Scoped to this runtime identity (not process-global) so two `PKRuntime`
        /// instances — documented to start independent histories — never contend over the
        /// same `(timelineID, toolCallId)` reservation keys (D-03).
        let submissionGate: ExternalToolOutputSubmissionGate

        init(
            timelineManager: TimelineManager,
            promptHistoryRegistry: TimelinePromptJournals,
            agentAuthorityCoordinator: AgentAuthorityCoordinator,
            eventHub: TurnEventHub,
            submissionGate: ExternalToolOutputSubmissionGate
        ) {
            self.timelineManager = timelineManager
            self.promptHistoryRegistry = promptHistoryRegistry
            self.agentAuthorityCoordinator = agentAuthorityCoordinator
            self.eventHub = eventHub
            self.submissionGate = submissionGate
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
    let messageStore: any TimelineMessageStoreProtocol
    /// Cohesive durable owner for Timeline history and Turn lifecycle.
    let runtimeRepository: any TimelineRuntimeRepository
    /// Durable authority for ordinary Workspace-to-Timeline bindings.
    let workspaceBindingRepository: any WorkspaceBindingRepository

    /// Internal coordinator shared by the capability values and turn engine.
    let timelineManager: TimelineManager

    /// Runtime-owned identities that must survive provider reconfiguration.
    private let runtimeState: RuntimeState


    /// Internal agent coordinator shared by the capability values and turn engine.
    let agentManager: AgentManager

    /// Internal tool router wired to the facade-owned Timeline coordinator.
    let toolRouter: ToolRouter

    /// Consumer-facing capability values. These keep orchestration managers behind the facade.
    public var timelines: TimelineCapability { TimelineCapability(kit: self) }
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
    let timelinePersistence: any TimelinePersistenceProtocol
    let workspacePersistence: any WorkspaceStore
    private let toolPersistence: any ToolPersistenceProtocol

    let turnEngine: TurnEngine

    /// Owned internally; every timeline driver vended by this instance shares it automatically.
    /// Construct a new `PKRuntime` for a genuinely separate cross-send history.
    private let promptHistoryRegistry: TimelinePromptJournals
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
                languageModel: languageModel,
                persistence: .inMemory()
            )
        )
    }

    /// Creates a facade from a configured provider value with in-memory persistence.
    ///
    /// Provider packages expose the concrete factory methods that create this
    /// value. Applications do not need to assemble ``LLMService`` or
    /// ``LLMClientSet`` for the common setup path. For durable stores, use the
    /// provider overload on ``PKRuntime/Configuration`` and pass it to
    /// ``PKRuntime/init(configuration:)``; that path also keeps both types out of the
    /// consumer's code.
    public convenience init(provider: ConfiguredLLMProvider) {
        self.init(configuration: .init(provider: provider, persistence: .inMemory()))
    }

    convenience init(
        languageModel: any LLMStreamClient,
        runtimeRepository: any TimelineRuntimeRepository,
        workspaceBindingRepository: any WorkspaceBindingRepository,
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
        sharedRegistry: TimelinePromptJournals,
        additionalStages: [any PipelineStage<TurnContext, TurnEvent>],
        streamTimeout: TimeInterval = TurnEngine.Dependencies.defaultStreamTimeout,
        terminalCommitStallLimit: TimeInterval = 300,
        clock: any RuntimeClock = ContinuousRuntimeClock()
    ) {
        // The binding repository is resolved exactly once, by `PersistenceConfiguration`
        // (ADR 0004: binding authority is repository-only). This seam receives it rather than
        // re-deriving it from an `as?` downcast of another store (C-02).
        let resolvedWorkspaceStore = workspacePersistence ?? InMemoryWorkspacePersistence()
        self.init(
            dependencies: KitDependencies(
                languageModel: languageModel,
                runtimeRepository: runtimeRepository,
                workspaceBindingRepository: workspaceBindingRepository,
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
                additionalStages: additionalStages,
                streamTimeout: streamTimeout,
                terminalCommitStallLimit: terminalCommitStallLimit,
                clock: clock
            )
        )
    }

    /// The designated initializer. Accepts a fully-resolved ``KitDependencies`` bundle and
    /// wires the internal coordinators (`TimelineManager`, `AgentManager`, `ToolRouter`,
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
        timelinePersistence = dependencies.runtimeRepository
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
        // path from timeline workspaces). For `.noWorkspace` there is no profile root, so fall
        // back to a process-temporary path so the catalog still has somewhere to anchor if a
        // host later creates agent workspaces. Timeline creation itself is unaffected: `.noWorkspace`
        // provisions no timeline directory regardless of this value.
        let resolvedTimelineManager: TimelineManager
        let resolvedEventHub: TurnEventHub
        let resolvedSubmissionGate: ExternalToolOutputSubmissionGate

        if let runtimeState {
            resolvedTimelineManager = runtimeState.timelineManager
            resolvedEventHub = runtimeState.eventHub
            resolvedSubmissionGate = runtimeState.submissionGate
        } else {
            // The facade is the only place a TimelineManager gets built: every store it wraps
            // comes from the same `persistence` surface the rest of the facade uses, so there is
            // no seam where TurnEngine and TimelineManager can end up looking at different stores.
            let newTimelineManager = TimelineManager(
                stores: .init(
                    timelineStore: self.timelinePersistence,
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
            resolvedTimelineManager = newTimelineManager
            resolvedEventHub = TurnEventHub()
            resolvedSubmissionGate = ExternalToolOutputSubmissionGate()
        }

        let resolvedCatalogRoot = dependencies.workspaceProfile.catalogRoot
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        let resolvedWorkspaceCatalog = DefaultWorkspaceCatalog(
            workspaceRoot: resolvedCatalogRoot,
            workspacePersistence: self.workspacePersistence,
            bindingRepository: self.workspaceBindingRepository,
            runtimeRepository: self.runtimeRepository,
            timelineAuthorityCoordinator: resolvedTimelineManager.timelineAuthorityCoordinator
        )
        let resolvedAgentManager = AgentManager(
            repository: resolvedWorkspaceCatalog,
            stores: .init(
                agentStore: self.agentStore,
                timelineStore: self.timelinePersistence,
                messageStore: self.messageStore,
                workspaceStore: self.workspacePersistence,
                runtimeRepository: self.runtimeRepository,
                timelineAuthorityCoordinator: resolvedTimelineManager.timelineAuthorityCoordinator,
                agentAuthorityCoordinator: resolvedAgentAuthorityCoordinator,
                eventHub: resolvedEventHub
            ),
            timelineManager: resolvedTimelineManager
        )
        let resolvedToolRouter = ToolRouter(
            timelineManager: resolvedTimelineManager,
            runtimeRepository: self.runtimeRepository,
            approvalPolicy: dependencies.toolApprovalPolicy,
            loggingConfiguration: dependencies.loggingConfiguration
        )

        let resolvedRuntimeState = runtimeState ?? RuntimeState(
            timelineManager: resolvedTimelineManager,
            promptHistoryRegistry: resolvedPromptHistoryRegistry,
            agentAuthorityCoordinator: resolvedAgentAuthorityCoordinator,
            eventHub: resolvedEventHub,
            submissionGate: resolvedSubmissionGate
        )
        self.runtimeState = resolvedRuntimeState
        timelineManager = resolvedRuntimeState.timelineManager
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
                timelineManager: resolvedTimelineManager,
                agentStore: self.agentStore,
                agentContextSource: self.customization.agentContextSource ?? DefaultAgentContextSource(
                    workspaceStore: dependencies.workspacePersistence
                ),
                requestOriginStore: self.requestOriginStore,
                runtimeRepository: self.runtimeRepository,
                timelineAuthorityCoordinator: resolvedTimelineManager.timelineAuthorityCoordinator,
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
                eventHub: resolvedEventHub,
                submissionGate: resolvedSubmissionGate,
                streamTimeout: dependencies.streamTimeout,
                clock: dependencies.clock,
                terminalCommitStallLimit: dependencies.terminalCommitStallLimit
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
            additionalStages: turnEngine.additionalStages,
            streamTimeout: turnEngine.dependencies.streamTimeout,
            terminalCommitStallLimit: turnEngine.dependencies.terminalCommitStallLimit,
            clock: turnEngine.dependencies.clock
        )
    }

    /// Returns a new facade with updated provider/generation configuration while preserving the
    /// current instance's runtime-owned cross-send state (prompt-history journal diffs and
    /// inspection turn indexing), stores, tools, plugins, and workspace wiring.
    ///
    /// This is the supported path for hosts that must refresh provider settings between sends
    /// without silently resetting per-timeline prompt-history state.
    public func reconfigured(
        languageModel: any LLMStreamClient,
        generationParameters: GenerationParameters? = nil
    ) -> PKRuntime {
        var deps = dependencies
        deps.languageModel = languageModel
        deps.generationParameters = generationParameters ?? defaultGenerationParameters
        return PKRuntime(dependencies: deps, runtimeState: runtimeState)
    }

    // MARK: - Builder

    /// Adds a custom stage to the chat execution pipeline.
    /// - Parameter stage: The custom pipeline stage to add.
    /// - Returns: A new instance with the stage added.
    ///
    /// This remains package-internal and is reserved for runtime-owned verification stages; it is
    /// not a consumer customization surface.
    func addingStage(_ stage: any PipelineStage<TurnContext, TurnEvent>) -> PKRuntime {
        var deps = dependencies
        deps.additionalStages += [stage]
        return PKRuntime(dependencies: deps, runtimeState: runtimeState)
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
            timelineID: request.timelineID,
            eventStream: nonThrowingEvents(
                from: execution.stream,
                // Consumer cancellation must reach the Turn on the public path too, not only on
                // the engine-test `TurnEngine.execute(_:)` path.
                relay: turnEngine.consumerCancellationRelay(for: execution, timelineID: request.timelineID)
            ),
            kit: self
        )
    }

    /// Bridges the Turn's throwing event stream onto the nonthrowing stream a `TurnHandle`
    /// hands out, and relays consumer abandonment back to the Turn.
    ///
    /// This is the only hop between the Turn and its public consumer: the relay rides on this
    /// bridge rather than wrapping `source` in a second stream, so an abandoned consumer is
    /// observed without adding a task to every Turn.
    private func nonThrowingEvents(
        from source: AsyncThrowingStream<TurnEvent, Error>,
        relay: TurnEngine.ConsumerCancellationRelay
    ) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let reachedTerminalState = Mutex(false)
            let bridge = Task {
                var terminalDelivered = false
                do {
                    for try await event in source {
                        if event.isTerminal {
                            if terminalDelivered { continue }
                            terminalDelivered = true
                            // Set before the yield below: a consumer must not be able to observe
                            // the terminal event and break while the relay still thinks the Turn
                            // is live.
                            reachedTerminalState.withLock { $0 = true }
                        }
                        continuation.yield(event)
                    }
                } catch {
                    if !terminalDelivered {
                        continuation.yield(.error(error))
                    }
                }
                reachedTerminalState.withLock { $0 = true }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable termination in
                // Without this the bridge outlives an abandoned consumer and keeps draining
                // `source` for events nobody will read.
                bridge.cancel()
                guard case .cancelled = termination else { return }
                relay.consumerAbandoned(reachedTerminalState: reachedTerminalState.withLock { $0 })
            }
        }
    }

    func waitForTurnOutcome(id turnID: UUID) async throws -> TurnOutcome {
        let waiter = TurnTerminationWaiter(
            hub: runtimeState.eventHub,
            clock: turnEngine.dependencies.clock
        )
        let observation = try await waiter.awaitResult(turnID: turnID) {
            try await self.runtimeRepository.fetchTurn(id: turnID)?.outcome
        }
        switch observation {
        case let .value(outcome):
            return outcome
        case .timedOut:
            throw TurnOutcomeTimedOut(turnID: turnID)
        }
    }

    /// Waits for the Turn's terminal record, then resolves its consolidated result.
    ///
    /// Uses the same push-then-bounded-poll waiter as ``waitForTurnOutcome(id:)``,
    /// but fetches the full terminal `TurnRecord` and resolves
    /// `terminalMessageID` through the runtime repository's durable messages.
    /// A missing terminal message row yields `message == nil`; the outcome
    /// remains authoritative either way. Observation sinks and the prompt
    /// journal are never consulted.
    func waitForTurnResult(id turnID: UUID) async throws -> TurnResult {
        let waiter = TurnTerminationWaiter(
            hub: runtimeState.eventHub,
            clock: turnEngine.dependencies.clock
        )
        let observation = try await waiter.awaitResult(turnID: turnID) {
            let record = try await self.runtimeRepository.fetchTurn(id: turnID)
            return record.flatMap { $0.isTerminal ? $0 : nil }
        }
        switch observation {
        case let .value(record):
            guard let outcome = record.outcome else {
                throw TurnOutcomeTimedOut(turnID: turnID)
            }
            let message: Message?
            if let messageID = record.terminalMessageID {
                let messages = try await self.runtimeRepository.fetchMessages(for: record.timelineID)
                message = messages.first(where: { $0.id == messageID })?.toMessage()
            } else {
                message = nil
            }
            return TurnResult(
                turnID: turnID,
                timelineID: record.timelineID,
                outcome: outcome,
                message: message
            )
        case .timedOut:
            throw TurnOutcomeTimedOut(turnID: turnID)
        }
    }

    func cancelTurn(id turnID: UUID, timelineID: UUID) async {
        _ = await timelineManager.cancelGeneration(turnID: turnID, for: timelineID)
    }

    /// Runs the package-internal engine request and returns its throwing event stream.
    ///
    /// This is reserved for runtime-owned engine tests. Public callers admit Turns through a
    /// ``TimelineHandle`` and receive a ``TurnHandle`` instead.
    ///
    /// - Parameter request: The package-internal turn configuration.
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
