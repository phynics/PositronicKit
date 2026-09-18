import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities
import Synchronization

/// The entry point to PositronicKit: it turns a language model into an agent runtime that owns
/// durable Timelines, Agents, tool routing, and prompt assembly.
///
/// ```swift
/// let runtime = PKRuntime(languageModel: myModel)
/// let answer = try await runtime.model.generate("Summarize this release.")
/// ```
///
/// Only the language model is required; everything else defaults to in-memory stores that suit
/// prototyping and tests. For production, pass durable stores through
/// ``PKRuntime/init(configuration:)``.
///
/// ## Capabilities
///
/// Work goes through four capability values rather than the coordinators behind them:
///
/// - ``model`` — inference with no Timeline attached.
/// - ``timelines`` — durable Timeline handles and Turn execution.
/// - ``agents`` — Agent identity and attachment.
/// - ``workspaces`` — the Workspace catalog.
///
/// ## Lifetime and identity
///
/// Construct one runtime and hold it for the app's lifetime. `PKRuntime` is a reference type, and
/// each instance built through an ordinary initializer starts its own independent cross-send
/// history. To refresh provider settings between sends without resetting per-Timeline
/// prompt-history state, use ``reconfigured(languageModel:generationParameters:)``, which returns
/// a new view over the same runtime state rather than a new runtime.
///
/// ## Extension seams
///
/// `PKRuntime` stays transport-neutral: concrete networking and multi-process hosting arrive from
/// downstream applications through injected stores, workspace creators, and connection hooks. The
/// supported seams are the facade itself, the public persistence protocols, `WorkspaceFactory` /
/// `WorkspaceProvider`, and ``RuntimeCustomization``. Internal coordinators — `TurnEngine`,
/// `TimelinePromptHistory`, and the concrete Turn pipeline — remain implementation details even
/// where tests inside this package can see them.
public final class PKRuntime: Sendable {
    /// The resolved dependency bundle this runtime was built from.
    ///
    /// Stored whole rather than unpacked into individual properties: every field below that a
    /// caller reads is a one-line view onto it, and the builders (`reconfigured`, `addingStage`)
    /// copy this value, mutate one field, and forward it to ``init(dependencies:runtimeState:)``.
    let dependencies: KitDependencies

    // MARK: - Language Model Client
    var languageModelClient: any LLMStreamClient { dependencies.languageModel }

    /// Whether the injected language model currently has usable provider configuration.
    ///
    /// This reads the model's live readiness without exposing provider configuration,
    /// credentials, or mutation APIs through the facade.
    var isLanguageModelConfigured: Bool {
        get async { await languageModelClient.isConfigured }
    }

    // MARK: - External Stores
    /// Durable storage for messages and timelines
    var messageStore: any TimelineMessageStoreProtocol { dependencies.runtimeRepository }
    /// Cohesive durable owner for Timeline history and Turn lifecycle.
    var runtimeRepository: any TimelineRuntimeRepository { dependencies.runtimeRepository }
    /// Durable authority for ordinary Workspace-to-Timeline bindings.
    var workspaceBindingRepository: any WorkspaceBindingRepository {
        dependencies.workspaceBindingRepository
    }
    let workspaceCatalog: any WorkspaceCatalog
    // These resolved graph nodes remain package-internal for @testable assembly coverage.
    var timelinePersistence: any TimelinePersistenceProtocol { dependencies.runtimeRepository }
    var workspacePersistence: any WorkspaceStore { dependencies.workspacePersistence }
    
    // MARK: - Internal State
    
    /// Runtime-owned identities that must survive provider reconfiguration.
    private let runtimeState: RuntimeState
    /// Internal coordinator shared by the capability values and turn engine.
    let timelineManager: TimelineManager
    /// Internal agent coordinator shared by the capability values and turn engine.
    let agentManager: AgentManager
    /// Internal tool router wired to the facade-owned Timeline coordinator.
    let toolRouter: ToolRouter
    let turnEngine: TurnEngine
    let agentAuthorityCoordinator: AgentAuthorityCoordinator
    var defaultGenerationParameters: GenerationParameters? { dependencies.generationParameters }

    private let logger = Logger.module(named: "positronickit-facade")

    /// Consumer-facing capability values. These keep orchestration managers behind the facade.
    public var timelines: TimelineCapability { TimelineCapability(kit: self) }
    public var agents: AgentCapability { AgentCapability(kit: self) }
    public var workspaces: WorkspaceCapability { WorkspaceCapability(kit: self) }
    public var model: ModelInferenceCapability { ModelInferenceCapability(kit: self) }
    
    /// Owned internally; every timeline driver vended by this instance shares it automatically.
    /// Construct a new `PKRuntime` for a genuinely separate cross-send history.
    private var promptHistoryRegistry: TimelinePromptJournals { dependencies.sharedRegistry }

    // MARK: - Init
    /// The designated initializer. Accepts a fully-resolved ``KitDependencies`` bundle and
    /// wires the internal coordinators (`TimelineManager`, `AgentManager`, `ToolRouter`,
    /// `TurnEngine`) from it. The provider reconfiguration builder
    /// extract the current dependencies, mutate the single field that changes, and forward
    /// here — eliminating the repeated ~25-line parameter forwarding (PKCR-009).
    internal init(dependencies: KitDependencies, runtimeState: RuntimeState? = nil) {
        let resolvedAgentAuthorityCoordinator = runtimeState?.agentAuthorityCoordinator
            ?? dependencies.agentAuthorityCoordinator
            ?? AgentAuthorityCoordinator()
        agentAuthorityCoordinator = resolvedAgentAuthorityCoordinator

        let resolvedPromptHistoryRegistry = runtimeState?.promptHistoryRegistry
            ?? dependencies.sharedRegistry

        // Store the bundle with the two runtime-resolved identities written back, so a builder
        // that copies it forwards the identities this instance actually uses rather than the
        // ones it was asked for.
        var resolvedDependencies = dependencies
        resolvedDependencies.agentAuthorityCoordinator = resolvedAgentAuthorityCoordinator
        resolvedDependencies.sharedRegistry = resolvedPromptHistoryRegistry
        self.dependencies = resolvedDependencies

        var activitySinks: [any AgentActivitySink] = []
        if let hostActivitySink = dependencies.customization.agentActivitySink {
            activitySinks.append(hostActivitySink)
        }
        let resolvedActivitySink: any AgentActivitySink? = activitySinks.isEmpty
            ? nil
            : AgentActivityFanout(sinks: activitySinks)

        // One finalizer per runtime identity: `reconfigured` views share it so they see each
        // other's in-flight terminal commits instead of treating them as orphans (ADR 0010).
        let resolvedFinalizer = runtimeState?.finalizer ?? TurnFinalizer(
            repository: dependencies.runtimeRepository,
            agentActivitySink: resolvedActivitySink,
            turnOutcomeSink: dependencies.customization.turnOutcomeSink,
            clock: dependencies.policy.clock
        )

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
                    timelineStore: dependencies.runtimeRepository,
                    messageStore: dependencies.runtimeRepository,
                    workspaceStore: dependencies.workspacePersistence,
                    workspaceBindingRepository: dependencies.workspaceBindingRepository,
                    runtimeRepository: dependencies.runtimeRepository,
                    toolPersistence: dependencies.toolPersistence
                ),
                workspaceProfile: dependencies.workspaceProfile,
                workspaceCreator: dependencies.workspaceCreator,
                runtimeToolPolicy: dependencies.runtimeToolPolicy,
                promptHistoryRegistry: resolvedPromptHistoryRegistry,
                finalizer: resolvedFinalizer
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
            workspacePersistence: dependencies.workspacePersistence,
            bindingRepository: dependencies.workspaceBindingRepository,
            runtimeRepository: dependencies.runtimeRepository,
            timelineAuthorityCoordinator: resolvedTimelineManager.timelineAuthorityCoordinator
        )
        let resolvedAgentManager = AgentManager(
            repository: resolvedWorkspaceCatalog,
            stores: .init(
                agentStore: dependencies.agentStore,
                timelineStore: dependencies.runtimeRepository,
                messageStore: dependencies.runtimeRepository,
                workspaceStore: dependencies.workspacePersistence,
                runtimeRepository: dependencies.runtimeRepository,
                timelineAuthorityCoordinator: resolvedTimelineManager.timelineAuthorityCoordinator,
                agentAuthorityCoordinator: resolvedAgentAuthorityCoordinator,
                eventHub: resolvedEventHub
            ),
            timelineManager: resolvedTimelineManager
        )
        let resolvedToolRouter = ToolRouter(
            timelineManager: resolvedTimelineManager,
            runtimeRepository: dependencies.runtimeRepository,
            approvalPolicy: dependencies.toolApprovalPolicy,
            loggingConfiguration: dependencies.policy.loggingConfiguration
        )

        let resolvedRuntimeState = runtimeState ?? RuntimeState(
            timelineManager: resolvedTimelineManager,
            promptHistoryRegistry: resolvedPromptHistoryRegistry,
            agentAuthorityCoordinator: resolvedAgentAuthorityCoordinator,
            eventHub: resolvedEventHub,
            submissionGate: resolvedSubmissionGate,
            finalizer: resolvedFinalizer
        )
        self.runtimeState = resolvedRuntimeState
        timelineManager = resolvedRuntimeState.timelineManager
        workspaceCatalog = resolvedWorkspaceCatalog
        agentManager = resolvedAgentManager
        toolRouter = resolvedToolRouter

        var engine = TurnEngine(
            dependencies: .init(
                timelineManager: resolvedTimelineManager,
                agentStore: dependencies.agentStore,
                agentContextSource: dependencies.customization.agentContextSource ?? DefaultAgentContextSource(
                    workspaceStore: dependencies.workspacePersistence
                ),
                requestOriginStore: dependencies.requestOriginStore,
                runtimeRepository: dependencies.runtimeRepository,
                timelineAuthorityCoordinator: resolvedTimelineManager.timelineAuthorityCoordinator,
                agentAuthorityCoordinator: self.agentAuthorityCoordinator,
                llmService: dependencies.languageModel,
                toolRouter: toolRouter,
                turnContextSource: dependencies.customization.turnContextSource,
                agentActivitySink: resolvedActivitySink,
                turnOutcomeSink: dependencies.customization.turnOutcomeSink,
                promptHistoryRegistry: resolvedPromptHistoryRegistry,
                eventHub: resolvedEventHub,
                submissionGate: resolvedSubmissionGate,
                finalizer: resolvedRuntimeState.finalizer,
                policy: dependencies.policy
            )
        )
        engine.additionalStages = dependencies.additionalStages
        turnEngine = engine
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
            clock: turnEngine.dependencies.policy.clock
        )
        let observation = try await waiter.awaitResult(turnID: turnID) {
            try await dependencies.runtimeRepository.fetchTurn(id: turnID)?.outcome
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
            clock: turnEngine.dependencies.policy.clock
        )
        let observation = try await waiter.awaitResult(turnID: turnID) {
            let record = try await dependencies.runtimeRepository.fetchTurn(id: turnID)
            return record.flatMap { $0.isTerminal ? $0 : nil }
        }
        switch observation {
        case let .value(record):
            guard let outcome = record.outcome else {
                throw TurnOutcomeTimedOut(turnID: turnID)
            }
            let message: Message?
            if let messageID = record.terminalMessageID {
                let messages = try await dependencies.runtimeRepository.fetchMessages(for: record.timelineID)
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
