import Foundation
import PKContracts
import PositronicKit

/// The optional runtime adapter that installs the filesystem Agent conventions.
///
/// `PositronicKit` itself is neutral: the default Agent context source is identity-only, no Agent
/// write is approval-gated, and no identity or Notes templates are seeded. This adapter restores
/// the opinionated filesystem behavior as a set of values a host composes into its runtime
/// configuration.
public enum PKAgentFiles {
    /// Primary-Workspace-relative paths that require write approval when the adapter is installed.
    public static let protectedPaths: [String] = ["SOUL.md"]

    /// The generic Agent-workspace seed carrying the identity-file and `Notes/` templates.
    public static let seedNotes = AgentWorkspaceSeed(
        identityFilename: "SOUL.md",
        identityContent: { template in
            let identity = template?.composedInstructions ?? "You are a helpful PKRuntime Agent."
            return """
            \(identity)

            ## Memory system
            Persistent memory lives in Markdown files under `Notes/`. The runtime provides a compact
            catalog of those files; read a file with `read_file` when its contents are relevant, and
            use `write_file`, `append_file`, or `edit_file` to maintain durable state. Keep notes
            concise, factual, and scoped to information that should survive future Timelines.

            ## Self-modification
            This file defines the Agent's identity and operating guidance. Changes to `SOUL.md` require
            explicit user approval and take effect on the next Turn. Do not weaken safety boundaries,
            conceal changes, or treat an unapproved edit as complete. Ordinary files in the private
            workspace may be maintained without approval.
            """
        },
        notes: ["MEMORY.md": """
        # Memory

        Keep durable facts, preferences, and decisions here. Prefer short, dated entries and link to
        more specific notes when a topic grows. Read the Notes catalog first, then load this file only
        when the current task needs it.
        """]
    )

    /// The filesystem Agent context source over `workspaceStore`.
    public static func contextSource(workspaceStore: any WorkspaceStore) -> any AgentContextSource {
        FileSystemAgentContextSource(workspaceStore: workspaceStore)
    }
}

public extension RuntimeCustomization {
    /// Installs the filesystem Agent context source and Agent-workspace seed over `base`.
    ///
    /// The write-approval gate is a separate value:
    /// `RuntimeToolPolicy(protectedPrimaryWorkspacePaths: PKAgentFiles.protectedPaths)`.
    /// ``PKRuntime/RuntimeConfiguration/agentFiles(persistence:workspaceProfile:base:)`` sets all
    /// three at once.
    static func agentFiles(
        workspaceStore: any WorkspaceStore,
        base: RuntimeCustomization = .default
    ) -> RuntimeCustomization {
        RuntimeCustomization(
            agentContextSource: FileSystemAgentContextSource(workspaceStore: workspaceStore),
            turnContextSource: base.turnContextSource,
            turnHistoryProjectionSource: base.turnHistoryProjectionSource,
            agentActivitySink: base.agentActivitySink,
            turnOutcomeSink: base.turnOutcomeSink,
            agentWorkspaceSeed: PKAgentFiles.seedNotes
        )
    }
}

public extension PKRuntime.RuntimeConfiguration {
    /// Installs the three filesystem Agent conventions over `base`: the context source, the
    /// Agent-workspace seed, and the protected-path write gate.
    static func agentFiles(
        persistence: PKRuntime.PersistenceConfiguration,
        workspaceProfile: WorkspaceProfile = .noWorkspace,
        base: PKRuntime.RuntimeConfiguration = .default
    ) -> PKRuntime.RuntimeConfiguration {
        PKRuntime.RuntimeConfiguration(
            workspaceProfile: workspaceProfile,
            workspaceCreator: base.workspaceCreator,
            customization: .agentFiles(workspaceStore: persistence.workspacePersistence, base: base.customization),
            runtimeToolPolicy: RuntimeToolPolicy(
                installFilesystemTools: base.runtimeToolPolicy.installFilesystemTools,
                installTimelineObservationTools: base.runtimeToolPolicy.installTimelineObservationTools,
                installsTimelineSendTool: base.runtimeToolPolicy.installsTimelineSendTool,
                protectedPrimaryWorkspacePaths: PKAgentFiles.protectedPaths
            ),
            toolApprovalPolicy: base.toolApprovalPolicy,
            diagnosticSnapshotConfiguration: base.diagnosticSnapshotConfiguration,
            degradationPolicy: base.degradationPolicy,
            streamTimeout: base.streamTimeout,
            terminalCommitStallLimit: base.terminalCommitStallLimit,
            promptCaching: base.promptCaching,
            retainsSiblingPrefix: base.retainsSiblingPrefix
        )
    }
}
