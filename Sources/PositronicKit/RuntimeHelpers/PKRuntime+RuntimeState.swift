//
//  PKRuntime+RuntimeState.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 18.09.26.
//

internal extension PKRuntime {
    /// Identity-bearing process-local runtime state shared by facade views created through
    /// `reconfigured`. Provider-facing configuration remains on each view's `TurnEngine`.
    final class RuntimeState: Sendable {
        let timelineManager: TimelineManager
        let promptHistoryRegistry: TimelinePromptJournals
        let agentAuthorityCoordinator: AgentAuthorityCoordinator
        let eventHub: TurnEventHub
        /// Scoped to this runtime identity (not process-global) so two `PKRuntime`
        /// instances — documented to start independent histories — never contend over the
        /// same `(timelineID, toolCallId)` reservation keys (D-03).
        let submissionGate: ExternalToolOutputSubmissionGate
        /// Runtime-owned terminal-commit executor. Shared across `reconfigured` views so a
        /// view cannot mistake another view's in-flight commit for an orphan (ADR 0010).
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
    }
}
