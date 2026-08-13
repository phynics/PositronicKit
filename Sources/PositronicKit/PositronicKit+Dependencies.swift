import Foundation
import PKShared
import PKUtilities

/// Bundles the resolved stores, managers, and configuration that ``PositronicKit`` needs to
/// construct its internal coordinators (`ThreadManager`, `AgentInstanceManager`, `ToolRouter`,
/// `ChatEngine`).
///
/// Used internally to eliminate the ~25-line parameter forwarding repeated by the builder
/// methods (`reconfigured`, `addingStage`, `addingPlugin`): each builder extracts the current
/// dependencies via ``PositronicKit/dependencies``, mutates the single field that changes, and
/// forwards the struct to the designated initializer
/// ``PositronicKit/init(dependencies:)``.
///
/// Not part of the public API surface.
internal struct KitDependencies: Sendable {
    var languageModel: any LanguageModel
    var messageStore: any MessageStoreProtocol
    var agentInstanceStore: any AgentInstanceStoreProtocol
    var requestOriginStore: any RequestOriginStoreProtocol
    var threadPersistence: any ThreadPersistenceProtocol
    var workspacePersistence: any WorkspaceStore
    var memoryStore: any MemoryStoreProtocol
    var toolPersistence: any ToolPersistenceProtocol
    var embeddingService: any EmbeddingServiceProtocol
    var workspaceProfile: WorkspaceProfile
    var workspaceCreator: any WorkspaceFactory
    var sectionProviders: [any PromptSectionProviding]
    var runtimeToolPolicy: ThreadManager.RuntimeToolPolicy
    var chatTurnPlugins: [any ChatTurnPlugin]
    var promptObserver: (any PromptObserving)?
    var diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
    var degradationPolicy: TurnDegradationPolicy
    var generationParameters: GenerationParameters?
    var toolApprovalPolicy: any ToolApprovalPolicy
    var loggingConfiguration: LoggingConfiguration
    var sharedRegistry: TimelinePromptJournals
    var additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>]
}
