import Foundation
import PKContracts
import PKUtilities

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
/// prompt-history state, use ``replacingLanguageModel(_:generationParameters:)``, which returns
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
    /// caller reads is a one-line view onto it, and ``replacingLanguageModel(_:generationParameters:)``
    /// copies this value, mutates the provider-configured fields, and forwards it to
    /// ``init(dependencies:runtimeState:)``.
    let dependencies: RuntimeDependencies

    // MARK: - Language Model Client
    var languageModelClient: any LLMStreamClient { dependencies.languageModel }

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
    /// Remains package-internal for @testable assembly coverage.
    var workspacePersistence: any WorkspaceStore { dependencies.workspacePersistence }
    
    // MARK: - Internal State
    
    /// Runtime-owned identities that must survive provider reconfiguration.
    private let runtimeState: RuntimeState

    /// Live ephemeral Timeline lifetimes shared by every replacement view of this runtime
    /// identity. A fork's handle carries a token from here; releasing the last token deletes the
    /// fork Timeline.
    var ephemeralRegistry: EphemeralTimelineRegistry { runtimeState.ephemeralRegistry }

    /// Waits for the runtime to finish deleting an ephemeral Timeline after its last handle is
    /// released. A bounded diagnostic and test seam: the release path schedules cleanup in an
    /// unstructured task because a value-typed handle cannot own asynchronous lifetime work.
    func awaitEphemeralTimelineReleased(_ timelineID: UUID, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while ephemeralRegistry.contains(timelineID), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Internal coordinator shared by the capability values and turn engine.
    let timelineManager: TimelineManager
    /// Internal agent coordinator shared by the capability values and turn engine.
    let agentManager: AgentManager
    /// Internal tool router wired to the facade-owned Timeline coordinator.
    let toolRouter: ToolRouter
    let turnEngine: TurnEngine
    let agentAuthorityCoordinator: AgentAuthorityCoordinator
    var defaultGenerationParameters: GenerationParameters? { dependencies.policy.generationParameters }

    /// Consumer-facing capability values. These keep orchestration managers behind the facade.
    public var timelines: TimelineCapability {
        TimelineCapability(
            timelineManager: timelineManager,
            agentManager: agentManager,
            messageStore: messageStore,
            turnEngine: turnEngine,
            runtime: self
        )
    }
    public var agents: AgentCapability { AgentCapability(agentManager: agentManager) }
    public var workspaces: WorkspaceCapability {
        WorkspaceCapability(
            workspaceCatalog: workspaceCatalog,
            attachWorkspaceToTimeline: { [timelineManager] workspaceID, timelineID in
                try await timelineManager.attachWorkspace(workspaceID, to: timelineID)
            }
        )
    }
    public var model: ModelInferenceCapability {
        ModelInferenceCapability(
            languageModelClient: languageModelClient,
            streamTimeout: dependencies.policy.streamTimeout,
            generationParameters: dependencies.policy.generationParameters,
            clock: dependencies.policy.clock,
            promptCaching: dependencies.policy.promptCaching
        )
    }
    
    // MARK: - Init
    /// The designated initializer. Accepts a fully-resolved ``RuntimeDependencies`` bundle and
    /// wires the internal coordinators (`TimelineManager`, `AgentManager`, `ToolRouter`,
    /// `TurnEngine`) from it. ``replacingLanguageModel(_:generationParameters:)`` extracts the
    /// current dependencies, mutates the provider-configured fields, and forwards here (PKCR-009).
    internal init(dependencies: RuntimeDependencies, runtimeState existingState: RuntimeState? = nil) {
        let activitySink = PKRuntime.makeActivitySink(dependencies: dependencies)
        let state = RuntimeState.resolve(
            dependencies: dependencies,
            existing: existingState,
            activitySink: activitySink
        )

        // Store the bundle with the runtime-resolved identities written back, so a builder that
        // copies it forwards the identities this instance actually uses rather than the ones it
        // was asked for.
        var resolvedDependencies = dependencies
        resolvedDependencies.agentAuthorityCoordinator = state.agentAuthorityCoordinator
        resolvedDependencies.sharedRegistry = state.promptHistoryRegistry
        self.dependencies = resolvedDependencies

        runtimeState = state
        timelineManager = state.timelineManager
        agentAuthorityCoordinator = state.agentAuthorityCoordinator

        let catalog = PKRuntime.makeWorkspaceCatalog(dependencies: resolvedDependencies, state: state)
        workspaceCatalog = catalog
        let router = PKRuntime.makeToolRouter(dependencies: resolvedDependencies, state: state)
        toolRouter = router
        agentManager = PKRuntime.makeAgentManager(
            dependencies: resolvedDependencies,
            state: state,
            workspaceCatalog: catalog
        )
        turnEngine = PKRuntime.makeTurnEngine(
            dependencies: resolvedDependencies,
            state: state,
            toolRouter: router,
            activitySink: activitySink
        )

        // Recovery sweep: an ephemeral Timeline present before this runtime created one is an
        // orphan from a previous process. The manager stores the sweep task so `fork` can await
        // it before creating a new ephemeral Timeline.
        let sweepManager = state.timelineManager
        Task { await sweepManager.ensureEphemeralSweepStarted() }
    }

    /// Returns a new provider-facing view with a replacement language model and, optionally,
    /// replacement default generation parameters, while preserving the current instance's
    /// runtime-owned cross-send state (prompt-history journal diffs and inspection turn indexing),
    /// stores, tools, plugins, and workspace wiring.
    ///
    /// Provider configuration is view-local. Handles opened from the original instance keep
    /// sending through the original model; only handles opened from the returned view use the
    /// replacement. The shared runtime-owned state carries no provider settings, so replacing a
    /// model never changes an in-flight Turn.
    ///
    /// This is the supported path for hosts that must refresh provider settings between sends
    /// without silently resetting per-timeline prompt-history state.
    public func replacingLanguageModel(
        _ languageModel: any LLMStreamClient,
        generationParameters: GenerationParameters? = nil
    ) -> PKRuntime {
        var deps = dependencies
        deps.languageModel = languageModel
        deps.policy.generationParameters = generationParameters ?? defaultGenerationParameters
        return PKRuntime(dependencies: deps, runtimeState: runtimeState)
    }
}
