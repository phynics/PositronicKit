//
//  PKRuntime+Init.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 18.09.26.
//

import Foundation
import PKContracts
import PKUtilities

extension PKRuntime {
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
        runtimeRepository: any TimelineRuntimeRepository = InMemoryTimelineRuntimeRepository(),
        workspaceBindingRepository: any WorkspaceBindingRepository = InMemoryWorkspaceBindingRepository(),
        agentStore: any AgentStoreProtocol = InMemoryAgentStore(),
        requestOriginStore: any RequestOriginStoreProtocol = InMemoryRequestOriginStore(),
        workspacePersistence: any WorkspaceStore = InMemoryWorkspacePersistence(),
        toolPersistence: any ToolPersistenceProtocol = InMemoryToolPersistence(),
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

        self.init(
            dependencies: KitDependencies(
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
}
