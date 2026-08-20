import Foundation
import PKContracts
import PKUtilities

/// Builds a `ThreadToolRegistry` for a session from a `RuntimeToolPolicy` and the thread's
/// attached-agent identity. Pure function with no side effects on the thread cache.
///
/// Extracted from `ThreadManager.createToolManager(for:jailRoot:)` so the
/// runtime tool-installation policy has its own testable surface — exercised without bringing up
/// a full `ThreadManager` (PKARCH-003).
package enum RuntimeToolPolicyFactory {
    package static func createToolManager(
        for thread: Thread,
        jailRoot: String,
        runtimeToolPolicy: RuntimeToolPolicy,
        threadStore: any ThreadPersistenceProtocol,
        messageStore: any ThreadMessageStoreProtocol
    ) -> ThreadToolRegistry {
        let currentWD = thread.workingDirectory ?? jailRoot
        // Default runtime policy: these filesystem and thread observation tools are installed by
        // default for every thread-managed session. Thread send is additionally installed when
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

        if runtimeToolPolicy.installThreadObservationTools {
            availableTools.append(contentsOf: [
                AnyTool(ThreadListTool(threadStore: threadStore)),
                AnyTool(ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)),
            ])
        }

        // Thread Send: only available when an agent is attached (needs sender identity)
        if runtimeToolPolicy.installThreadSendTool, let agentId = thread.attachedAgentID {
            availableTools.append(AnyTool(ThreadSendTool(
                messageStore: messageStore,
                threadStore: threadStore,
                agentID: agentId,
                sourceThreadID: thread.id
            )))
        }

        return ThreadToolRegistry(
            availableTools: availableTools
        )
    }

}
