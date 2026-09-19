import Foundation
import PKContracts
import PKUtilities

/// Construction steps for the coordinators the facade owns.
///
/// The designated initializer wires these together; extracting each construction keeps that
/// initializer a short list of assignments while leaving the graph itself in one place. This is
/// deliberately not a `RuntimeAssembly`: there is no normalized graph or independent seam here,
/// only the facade's own assembly of the coordinators it already owns.
internal extension PKRuntime {
    /// The host's Agent-activity sink wrapped in fan-out form, or `nil` when the host registered
    /// none.
    static func makeActivitySink(dependencies: RuntimeDependencies) -> any AgentActivitySink? {
        guard let hostActivitySink = dependencies.customization.agentActivitySink else { return nil }
        return AgentActivityFanout(sinks: [hostActivitySink])
    }

    /// The Workspace catalog anchored at the configured profile root.
    ///
    /// Agent-private workspace provisioning is opt-in and separate from timeline workspaces. For
    /// `.noWorkspace` there is no profile root, so the catalog falls back to a process-temporary
    /// path so a host that later creates agent workspaces still has an anchor. Timeline creation
    /// itself is unaffected: `.noWorkspace` provisions no timeline directory regardless of this
    /// value.
    static func makeWorkspaceCatalog(
        dependencies: RuntimeDependencies,
        state: RuntimeState
    ) -> any WorkspaceCatalog {
        let resolvedCatalogRoot = dependencies.workspaceProfile.catalogRoot
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        return DefaultWorkspaceCatalog(
            workspaceRoot: resolvedCatalogRoot,
            workspacePersistence: dependencies.workspacePersistence,
            bindingRepository: dependencies.workspaceBindingRepository,
            runtimeRepository: dependencies.runtimeRepository,
            timelineAuthorityCoordinator: state.timelineManager.timelineAuthorityCoordinator
        )
    }

    /// The Agent coordinator, rebuilt for each provider-facing view.
    static func makeAgentManager(
        dependencies: RuntimeDependencies,
        state: RuntimeState,
        workspaceCatalog: any WorkspaceCatalog
    ) -> AgentManager {
        AgentManager(
            repository: workspaceCatalog,
            stores: .init(
                agentStore: dependencies.agentStore,
                timelineStore: dependencies.runtimeRepository,
                messageStore: dependencies.runtimeRepository,
                workspaceStore: dependencies.workspacePersistence,
                runtimeRepository: dependencies.runtimeRepository,
                timelineAuthorityCoordinator: state.timelineManager.timelineAuthorityCoordinator,
                agentAuthorityCoordinator: state.agentAuthorityCoordinator,
                eventHub: state.eventHub
            ),
            timelineManager: state.timelineManager
        )
    }

    /// The tool router, rebuilt for each provider-facing view.
    static func makeToolRouter(
        dependencies: RuntimeDependencies,
        state: RuntimeState
    ) -> ToolRouter {
        ToolRouter(
            timelineManager: state.timelineManager,
            runtimeRepository: dependencies.runtimeRepository,
            approvalPolicy: dependencies.toolApprovalPolicy,
            loggingConfiguration: dependencies.policy.loggingConfiguration
        )
    }

    /// The Turn engine, rebuilt for each provider-facing view so it carries that view's provider,
    /// generation parameters, and additional stages while sharing the identity-bearing state.
    static func makeTurnEngine(
        dependencies: RuntimeDependencies,
        state: RuntimeState,
        toolRouter: ToolRouter,
        activitySink: any AgentActivitySink?
    ) -> TurnEngine {
        var engine = TurnEngine(
            dependencies: .init(
                timelineManager: state.timelineManager,
                agentStore: dependencies.agentStore,
                agentContextSource: dependencies.customization.agentContextSource
                    ?? DefaultAgentContextSource(workspaceStore: dependencies.workspacePersistence),
                requestOriginStore: dependencies.requestOriginStore,
                runtimeRepository: dependencies.runtimeRepository,
                timelineAuthorityCoordinator: state.timelineManager.timelineAuthorityCoordinator,
                agentAuthorityCoordinator: state.agentAuthorityCoordinator,
                llmService: dependencies.languageModel,
                toolRouter: toolRouter,
                turnContextSource: dependencies.customization.turnContextSource,
                agentActivitySink: activitySink,
                turnOutcomeSink: dependencies.customization.turnOutcomeSink,
                promptHistoryRegistry: state.promptHistoryRegistry,
                eventHub: state.eventHub,
                submissionGate: state.submissionGate,
                finalizer: state.finalizer,
                policy: dependencies.policy
            )
        )
        engine.additionalStages = dependencies.additionalStages
        return engine
    }
}
