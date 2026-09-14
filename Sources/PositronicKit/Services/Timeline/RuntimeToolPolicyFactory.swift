import Foundation
import PKContracts
import PKUtilities

/// Builds a `TimelineToolRegistry` for a timeline from a `RuntimeToolPolicy` and the timeline's
/// attached-agent identity. Pure function with no side effects on the timeline cache.
///
/// Extracted from `TimelineManager.createToolManager(for:jailRoot:)` so the
/// runtime tool-installation policy has its own testable surface — exercised without bringing up
/// a full `TimelineManager` (PKARCH-003).
package enum RuntimeToolPolicyFactory {
    package static func createToolManager(
        for timeline: TimelineRecord,
        jailRoot: String,
        runtimeToolPolicy: RuntimeToolPolicy,
        timelineStore: any TimelinePersistenceProtocol,
        messageStore: any TimelineMessageStoreProtocol
    ) -> TimelineToolRegistry {
        let currentWD = timeline.workingDirectory ?? jailRoot
        // Default runtime policy: these filesystem and timeline observation tools are installed by
        // default for every timeline-managed execution. Timeline send is additionally installed when
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
        if runtimeToolPolicy.installsTimelineSendTool, let agentId = timeline.attachedAgentID {
            availableTools.append(AnyTool(TimelineSendTool(
                messageStore: messageStore,
                timelineStore: timelineStore,
                agentID: agentId,
                sourceTimelineID: timeline.id
            )))
        }

        return TimelineToolRegistry(
            availableTools: availableTools
        )
    }

}
