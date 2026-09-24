//
//  PKRuntime+RuntimeState.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 18.09.26.
//

internal extension PKRuntime {
    /// Identity-bearing process-local runtime state shared by facade views created through
    /// ``PKRuntime/replacingLanguageModel(_:generationParameters:)``. Provider-facing
    /// configuration remains on each view's `TurnEngine`.
    final class RuntimeState: Sendable {
        let timelineManager: TimelineManager
        let promptHistoryRegistry: TimelinePromptJournals
        let agentAuthorityCoordinator: AgentAuthorityCoordinator
        let eventHub: TurnEventHub
        /// Scoped to this runtime identity (not process-global) so two `PKRuntime`
        /// instances — documented to start independent histories — never contend over the
        /// same `(timelineID, toolCallId)` reservation keys (D-03).
        let submissionGate: ExternalToolOutputSubmissionGate
        /// Runtime-owned terminal-commit executor. Shared across replacement views so a view
        /// cannot mistake another view's in-flight commit for an orphan (ADR 0010).
        let finalizer: TurnFinalizer
        
        init(
            timelineManager: TimelineManager,
            promptHistoryRegistry: TimelinePromptJournals,
            agentAuthorityCoordinator: AgentAuthorityCoordinator,
            eventHub: TurnEventHub,
            submissionGate: ExternalToolOutputSubmissionGate,
            finalizer: TurnFinalizer
        ) {
            self.timelineManager = timelineManager
            self.promptHistoryRegistry = promptHistoryRegistry
            self.agentAuthorityCoordinator = agentAuthorityCoordinator
            self.eventHub = eventHub
            self.submissionGate = submissionGate
            self.finalizer = finalizer
        }

        /// Resolves the identity-bearing state for one runtime identity.
        ///
        /// A provider-facing view created through
        /// ``PKRuntime/replacingLanguageModel(_:generationParameters:)`` reuses `existing` so its
        /// shared identities survive. A new identity builds the finalizer, Timeline manager, event
        /// hub, and submission gate; the facade is the only place a `TimelineManager` is built, so
        /// every store it wraps comes from the same dependency surface the rest of the facade uses.
        ///
        /// Only provider-configured dependencies may differ between views: the shared state keeps
        /// the first view's stores, workspace profile, tool policy, customization, and clock
        /// unchanged.
        static func resolve(
            dependencies: RuntimeDependencies,
            existing: RuntimeState?,
            activitySink: any AgentActivitySink?
        ) -> RuntimeState {
            if let existing { return existing }

            // One finalizer per runtime identity: replacement views share it so they see each
            // other's in-flight terminal commits instead of treating them as orphans (ADR 0010).
            let finalizer = TurnFinalizer(
                repository: dependencies.runtimeRepository,
                agentActivitySink: activitySink,
                turnOutcomeSink: dependencies.customization.turnOutcomeSink,
                clock: dependencies.policy.clock
            )
            let timelineManager = TimelineManager(
                stores: .init(
                    timelineStore: dependencies.runtimeRepository,
                    messageStore: dependencies.runtimeRepository,
                    workspaceStore: dependencies.workspacePersistence,
                    workspaceBindingRepository: dependencies.workspaceBindingRepository,
                    runtimeRepository: dependencies.runtimeRepository
                ),
                workspaceProfile: dependencies.workspaceProfile,
                workspaceCreator: dependencies.workspaceCreator,
                runtimeToolPolicy: dependencies.runtimeToolPolicy,
                promptHistoryRegistry: dependencies.sharedRegistry,
                finalizer: finalizer
            )
            return RuntimeState(
                timelineManager: timelineManager,
                promptHistoryRegistry: dependencies.sharedRegistry,
                agentAuthorityCoordinator: dependencies.agentAuthorityCoordinator ?? AgentAuthorityCoordinator(),
                eventHub: TurnEventHub(),
                submissionGate: ExternalToolOutputSubmissionGate(),
                finalizer: finalizer
            )
        }
    }
}
