import Foundation
import PKContracts
import PKUtilities

/// Bundles the resolved stores, managers, and configuration that ``PKRuntime`` needs to
/// construct its internal coordinators (`TimelineManager`, `AgentManager`, `ToolRouter`,
/// `TurnEngine`).
///
/// Used internally to eliminate the ~25-line parameter forwarding repeated by the builder
/// methods (`reconfigured`, `addingStage`): each builder extracts the current
/// dependencies via ``PKRuntime/dependencies``, mutates the single field that changes, and
/// forwards the struct to the designated initializer
/// ``PKRuntime/init(dependencies:)``.
///
/// Not part of the public API surface.
internal struct KitDependencies: Sendable {
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
    var diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
    var degradationPolicy: TurnDegradationPolicy
    var generationParameters: GenerationParameters?
    var toolApprovalPolicy: any ToolApprovalPolicy
    var loggingConfiguration: LoggingConfiguration
    var sharedRegistry: TimelinePromptJournals
    var additionalStages: [any PipelineStage<TurnContext, TurnEvent>]
    var streamTimeout: TimeInterval
    var terminalCommitStallLimit: TimeInterval
    var clock: any RuntimeClock
}
