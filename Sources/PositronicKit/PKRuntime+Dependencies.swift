import Foundation
import PKContracts
import PKUtilities

/// Bundles the resolved stores, managers, and configuration that ``PKRuntime`` needs to
/// construct its internal coordinators (`TimelineManager`, `AgentManager`, `ToolRouter`,
/// `TurnEngine`).
///
/// Used internally so ``PKRuntime/replacingLanguageModel(_:generationParameters:)`` can extract
/// the current dependencies via ``PKRuntime/dependencies``, mutate the provider-configured
/// fields, and forward the struct to the designated initializer
/// ``PKRuntime/init(dependencies:)``.
///
/// Not part of the public API surface.
internal struct RuntimeDependencies: Sendable {
    var languageModel: any LLMStreamClient
    var runtimeRepository: any TimelineRuntimeRepository
    var workspaceBindingRepository: any WorkspaceBindingRepository
    var agentStore: any AgentStoreProtocol
    var requestOriginStore: any RequestOriginStoreProtocol
    var workspacePersistence: any WorkspaceStore
    var toolPersistence: any ToolPersistenceProtocol
    var workspaceProfile: WorkspaceProfile
    var workspaceCreator: any WorkspaceFactory
    var customization: RuntimeCustomization
    var agentAuthorityCoordinator: AgentAuthorityCoordinator?
    var runtimeToolPolicy: RuntimeToolPolicy
    var toolApprovalPolicy: any ToolApprovalPolicy
    var sharedRegistry: TimelinePromptJournals
    var additionalStages: [any PipelineStage<TurnContext, TurnEvent>]
    /// The policy values forwarded to ``TurnEngine/Dependencies``.
    var policy: RuntimePolicy
}

extension RuntimeDependencies {
    /// Resolves a facade ``PKRuntime/Configuration`` plus the runtime-owned seams that
    /// configuration deliberately does not expose into the bundle the designated initializer
    /// consumes.
    ///
    /// `sharedRegistry` is the prompt-journal state shared across replacement views,
    /// `additionalStages` is reserved for runtime-owned verification stages, and `clock` exists so
    /// tests can drive the stream watchdog deterministically.
    init(
        configuration: PKRuntime.Configuration,
        sharedRegistry: TimelinePromptJournals,
        additionalStages: [any PipelineStage<TurnContext, TurnEvent>],
        clock: any RuntimeClock
    ) {
        self.init(
            languageModel: configuration.languageModel,
            runtimeRepository: configuration.persistence.runtimeRepository,
            workspaceBindingRepository: configuration.persistence.workspaceBindingRepository,
            agentStore: configuration.persistence.agentStore,
            requestOriginStore: configuration.persistence.requestOriginStore,
            workspacePersistence: configuration.persistence.workspacePersistence,
            toolPersistence: configuration.persistence.toolPersistence,
            workspaceProfile: configuration.runtime.workspaceProfile,
            workspaceCreator: configuration.runtime.workspaceCreator,
            customization: configuration.runtime.customization,
            agentAuthorityCoordinator: nil,
            runtimeToolPolicy: configuration.runtime.runtimeToolPolicy,
            toolApprovalPolicy: configuration.runtime.toolApprovalPolicy,
            sharedRegistry: sharedRegistry,
            additionalStages: additionalStages,
            policy: RuntimePolicy(
                streamTimeout: configuration.runtime.streamTimeout,
                terminalCommitStallLimit: configuration.runtime.terminalCommitStallLimit,
                degradationPolicy: configuration.runtime.degradationPolicy,
                diagnosticSnapshotConfiguration: configuration.runtime.diagnosticSnapshotConfiguration,
                loggingConfiguration: configuration.logging,
                clock: clock,
                generationParameters: configuration.generationParameters
            )
        )
    }
}
