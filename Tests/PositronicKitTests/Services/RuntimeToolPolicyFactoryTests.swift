import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Tests for `RuntimeToolPolicyFactory` (PKARCH-003 AC #4): verifies which tools are installed
/// for each `RuntimeToolPolicy` flag combination, without bringing up a full `TimelineManager`.
struct RuntimeToolPolicyFactoryTests {
    private func makeStores() -> (any TimelinePersistenceProtocol, any MessageStoreProtocol) {
        (InMemoryTimelinePersistence(), InMemoryMessageStore())
    }

    private func toolIds(for toolManager: TimelineToolRegistry) async -> Set<String> {
        Set(await toolManager.getAvailableTools().map(\.callName))
    }

    @Test("Default runtime tool set includes filesystem and timeline observation tools")
    func defaultToolManagerContract() async {
        let (timelineStore, messageStore) = makeStores()
        let timeline = Timeline(workingDirectory: "/tmp/test")
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: "/tmp/test",
            toolContextTimeline: ToolTimelineContext(),
            runtimeToolPolicy: .default,
            timelineStore: timelineStore,
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

    @Test("Timeline send is installed only when an agent is attached")
    func timelineSendRequiresAttachedAgent() async {
        let (timelineStore, messageStore) = makeStores()
        let timeline = Timeline(
            workingDirectory: "/tmp/test",
            attachedAgentInstanceId: UUID()
        )
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: "/tmp/test",
            toolContextTimeline: ToolTimelineContext(),
            runtimeToolPolicy: .default,
            timelineStore: timelineStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(ids.contains("timeline_send"))
    }

    @Test("Timeline send is NOT installed when no agent is attached, even with the policy flag on")
    func timelineSendAbsentWithoutAttachedAgent() async {
        let (timelineStore, messageStore) = makeStores()
        let timeline = Timeline(workingDirectory: "/tmp/test") // no attachedAgentInstanceId
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: "/tmp/test",
            toolContextTimeline: ToolTimelineContext(),
            runtimeToolPolicy: .default, // installTimelineSendTool = true
            timelineStore: timelineStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(!ids.contains("timeline_send"))
    }

    @Test("Selective runtime tool policy disables chosen categories only")
    func selectiveRuntimeToolPolicy() async {
        let (timelineStore, messageStore) = makeStores()
        let timeline = Timeline(
            workingDirectory: "/tmp/test",
            attachedAgentInstanceId: UUID()
        )
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: "/tmp/test",
            toolContextTimeline: ToolTimelineContext(),
            runtimeToolPolicy: .init(
                installFilesystemTools: false,
                installTimelineObservationTools: true,
                installTimelineSendTool: true
            ),
            timelineStore: timelineStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(ids == ["timeline_list", "timeline_peek", "timeline_send"])
    }

    @Test("Deny-all runtime tool policy installs no default tools")
    func denyAllRuntimeToolPolicy() async {
        let (timelineStore, messageStore) = makeStores()
        let timeline = Timeline(
            workingDirectory: "/tmp/test",
            attachedAgentInstanceId: UUID()
        )
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: "/tmp/test",
            toolContextTimeline: ToolTimelineContext(),
            runtimeToolPolicy: .denyAll,
            timelineStore: timelineStore,
            messageStore: messageStore
        )

        let ids = await toolIds(for: toolManager)
        #expect(ids.isEmpty)
    }

    @Test("Filesystem-only policy installs filesystem but not observation or send tools")
    func filesystemOnlyPolicy() async {
        let (timelineStore, messageStore) = makeStores()
        let timeline = Timeline(
            workingDirectory: "/tmp/test",
            attachedAgentInstanceId: UUID()
        )
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: "/tmp/test",
            toolContextTimeline: ToolTimelineContext(),
            runtimeToolPolicy: .init(
                installFilesystemTools: true,
                installTimelineObservationTools: false,
                installTimelineSendTool: false
            ),
            timelineStore: timelineStore,
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

    @Test("Tool context is propagated to the constructed TimelineToolRegistry")
    func toolContextPropagated() async {
        let (timelineStore, messageStore) = makeStores()
        let timeline = Timeline(workingDirectory: "/tmp/test")
        let toolContext = ToolTimelineContext()
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: "/tmp/test",
            toolContextTimeline: toolContext,
            runtimeToolPolicy: .denyAll,
            timelineStore: timelineStore,
            messageStore: messageStore
        )

        // `TimelineToolRegistry.timelineContext` is a public `let`.
        let ctx = await toolManager.timelineContext
        #expect(ctx != nil)
        #expect(ctx === toolContext)
    }
}