import Foundation
import PKContracts
import PKUtilities

/// Bundles the resolved stores, managers, and configuration that ``PositronicKit`` needs to
/// construct its internal coordinators (`ThreadManager`, `AgentManager`, `ToolRouter`,
/// `TurnEngine`).
///
/// Used internally to eliminate the ~25-line parameter forwarding repeated by the builder
/// methods (`reconfigured`, `addingStage`): each builder extracts the current
/// dependencies via ``PositronicKit/dependencies``, mutates the single field that changes, and
/// forwards the struct to the designated initializer
/// ``PositronicKit/init(dependencies:)``.
///
/// Not part of the public API surface.
internal struct KitDependencies: Sendable {
    var languageModel: any LLMStreamClient
    var runtimeRepository: any ThreadRuntimeRepository
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
    var sharedRegistry: ThreadPromptJournals
    var additionalStages: [any PipelineStage<TurnContext, TurnEvent>]
}
