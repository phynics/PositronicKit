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

    /// Resolves a ``PKRuntime/Configuration`` plus the runtime-owned seams that configuration
    /// deliberately does not expose, and forwards the result to the designated initializer.
    ///
    /// The three extra parameters are the internal seams: `sharedRegistry` is the prompt-journal
    /// state shared across `reconfigured` views, `additionalStages` is reserved for runtime-owned
    /// verification stages, and `clock` exists so tests can drive the stream watchdog
    /// deterministically. Consumers reach this through ``PKRuntime/init(configuration:)``.
    convenience init(
        configuration: Configuration,
        sharedRegistry: TimelinePromptJournals,
        additionalStages: [any PipelineStage<TurnContext, TurnEvent>],
        clock: any RuntimeClock = ContinuousRuntimeClock()
    ) {
        self.init(
            dependencies: KitDependencies(
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
                generationParameters: configuration.generationParameters,
                toolApprovalPolicy: configuration.runtime.toolApprovalPolicy,
                sharedRegistry: sharedRegistry,
                additionalStages: additionalStages,
                policy: RuntimePolicy(
                    streamTimeout: configuration.runtime.streamTimeout,
                    terminalCommitStallLimit: configuration.runtime.terminalCommitStallLimit,
                    degradationPolicy: configuration.runtime.degradationPolicy,
                    diagnosticSnapshotConfiguration: configuration.runtime.diagnosticSnapshotConfiguration,
                    loggingConfiguration: configuration.logging,
                    clock: clock
                )
            )
        )
        if let warning = configuration.persistence.validateDurability().mixedDurabilityWarning {
            configuration.logging.logger(named: "positronickit-facade").warning(
                "\(configuration.logging.redactionPolicy.sanitizeStructured(warning))"
            )
        }
    }
}
