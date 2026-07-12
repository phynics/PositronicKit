import Foundation
import PKShared

/// Builds a `TimelineToolRegistry` for a session from a `RuntimeToolPolicy` and the timeline's
/// attached-agent identity. Pure function with no side effects on the timeline cache.
///
/// Extracted from `TimelineManager.createToolManager(for:jailRoot:toolContextTimeline:)` so the
/// runtime tool-installation policy has its own testable surface — exercised without bringing up
/// a full `TimelineManager` (PKARCH-003).
package enum RuntimeToolPolicyFactory {
    package static func createToolManager(
        for timeline: Timeline,
        jailRoot: String,
        toolContextTimeline: ToolTimelineContext,
        runtimeToolPolicy: TimelineManager.RuntimeToolPolicy,
        timelineStore: any TimelinePersistenceProtocol,
        messageStore: any MessageStoreProtocol
    ) -> TimelineToolRegistry {
        let currentWD = timeline.workingDirectory ?? jailRoot

        // Default runtime policy: these filesystem and timeline observation tools are installed by
        // default for every timeline-managed session. Timeline send is additionally installed when
        // an attached agent identity is available, because it requires a sender identity.
        var availableTools: [AnyTool] = []

        if runtimeToolPolicy.installFilesystemTools {
            availableTools.append(contentsOf: [
                AnyTool(ChangeDirectoryTool(
                    currentPath: currentWD,
                    root: jailRoot,
                    onChange: { _ in
                        // Update working directory logic
                    }
                )),
                AnyTool(ListDirectoryTool(currentDirectory: currentWD, jailRoot: jailRoot)),
                AnyTool(FindFileTool(currentDirectory: currentWD, jailRoot: jailRoot)),
                AnyTool(SearchFileContentTool(currentDirectory: currentWD, jailRoot: jailRoot)),
                AnyTool(SearchFilesTool(currentDirectory: currentWD, jailRoot: jailRoot)),
                AnyTool(ReadFileTool(currentDirectory: currentWD, jailRoot: jailRoot)),
            ])
        }

        if runtimeToolPolicy.installTimelineObservationTools {
            availableTools.append(contentsOf: [
                AnyTool(TimelineListTool(timelineStore: timelineStore)),
                AnyTool(TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)),
            ])
        }

        // Timeline Send: only available when an agent is attached (needs sender identity)
        if runtimeToolPolicy.installTimelineSendTool, let agentId = timeline.attachedAgentInstanceId {
            availableTools.append(AnyTool(TimelineSendTool(
                messageStore: messageStore,
                timelineStore: timelineStore,
                agentInstanceId: agentId,
                sourceTimelineId: timeline.id
            )))
        }

        return TimelineToolRegistry(
            availableTools: availableTools,
            timelineContext: toolContextTimeline
        )
    }
}
