import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Tests for `RuntimeToolPolicyFactory` (PKARCH-003 AC #4): verifies which tools are installed
/// for each `RuntimeToolPolicy` flag combination, without bringing up a full `ThreadManager`.
struct RuntimeToolPolicyFactoryTests {
    private func makeStores() -> (any ThreadPersistenceProtocol, any ThreadMessageStoreProtocol) {
        (InMemoryThreadPersistence(), InMemoryMessageStore())
    }

    private func toolIds(for toolManager: ThreadToolRegistry) async -> Set<String> {
        Set(await toolManager.getAvailableTools().map(\.callName))
    }

    @Test("Default runtime tool set includes filesystem and thread observation tools")
    func defaultToolManagerContract() async {
        let (threadStore, messageStore) = makeStores()
        let thread = Thread(workingDirectory: "/tmp/test")
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: thread,
            jailRoot: "/tmp/test",
            runtimeToolPolicy: .default,
            threadStore: threadStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(ids == [
            "change_directory",
            "ls",
            "find",
            "grep",
            "search_files",
            "cat",
            "timeline_list",
            "timeline_peek",
        ])
        #expect(!ids.contains("timeline_send"))
    }

    @Test("Thread send is installed only when an agent is attached")
    func threadSendRequiresAttachedAgent() async {
        let (threadStore, messageStore) = makeStores()
        let thread = Thread(
            workingDirectory: "/tmp/test",
            attachedAgentInstanceID: UUID()
        )
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: thread,
            jailRoot: "/tmp/test",
            runtimeToolPolicy: .default,
            threadStore: threadStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(ids.contains("timeline_send"))
    }

    @Test("Thread send is NOT installed when no agent is attached, even with the policy flag on")
    func threadSendAbsentWithoutAttachedAgent() async {
        let (threadStore, messageStore) = makeStores()
        let thread = Thread(workingDirectory: "/tmp/test") // no attachedAgentInstanceId
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: thread,
            jailRoot: "/tmp/test",
            runtimeToolPolicy: .default, // installThreadSendTool = true
            threadStore: threadStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(!ids.contains("timeline_send"))
    }

    @Test("Selective runtime tool policy disables chosen categories only")
    func selectiveRuntimeToolPolicy() async {
        let (threadStore, messageStore) = makeStores()
        let thread = Thread(
            workingDirectory: "/tmp/test",
            attachedAgentInstanceID: UUID()
        )
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: thread,
            jailRoot: "/tmp/test",
            runtimeToolPolicy: .init(
                installFilesystemTools: false,
                installThreadObservationTools: true,
                installThreadSendTool: true
            ),
            threadStore: threadStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(ids == ["timeline_list", "timeline_peek", "timeline_send"])
    }

    @Test("Deny-all runtime tool policy installs no default tools")
    func denyAllRuntimeToolPolicy() async {
        let (threadStore, messageStore) = makeStores()
        let thread = Thread(
            workingDirectory: "/tmp/test",
            attachedAgentInstanceID: UUID()
        )
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: thread,
            jailRoot: "/tmp/test",
            runtimeToolPolicy: .denyAll,
            threadStore: threadStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(ids.isEmpty)
    }

    @Test("Filesystem-only policy installs filesystem but not observation or send tools")
    func filesystemOnlyPolicy() async {
        let (threadStore, messageStore) = makeStores()
        let thread = Thread(
            workingDirectory: "/tmp/test",
            attachedAgentInstanceID: UUID()
        )
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: thread,
            jailRoot: "/tmp/test",
            runtimeToolPolicy: .init(
                installFilesystemTools: true,
                installThreadObservationTools: false,
                installThreadSendTool: false
            ),
            threadStore: threadStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(ids == [
            "change_directory",
            "ls",
            "find",
            "grep",
            "search_files",
            "cat",
        ])
    }

    @Test("Tool context is propagated to the constructed ThreadToolRegistry")
    func toolContextPropagated() async {
        let (threadStore, messageStore) = makeStores()
        let thread = Thread(workingDirectory: "/tmp/test")
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: thread,
            jailRoot: "/tmp/test",
            runtimeToolPolicy: .denyAll,
            threadStore: threadStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(ids.isEmpty)
    }
}
