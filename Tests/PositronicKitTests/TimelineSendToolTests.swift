import Foundation
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

/// Regression coverage for the cross-agent `timeline_send` recursion guard.
///
/// The guard previously never fired: `createToolManager` always built `TimelineSendTool` with a
/// hardcoded depth of 0, so every send was treated as the first hop regardless of how deep the
/// source timeline's history already was. The tool must derive its current depth from the source
/// timeline's message history instead.
///
/// Post-PKARCH-003: tests build tools via `RuntimeToolPolicyFactory` directly, with the same
/// stores the original `TimelineManager.createToolManager` used, so `TimelineManager` is no longer
/// exercised in this single-tool regression suite.
@Suite("Timeline Send Tool")
struct TimelineSendToolTests {
    private func sendTool(
        timelineStore: InMemoryTimelinePersistence,
        messageStore: InMemoryMessageStore,
        source: Timeline,
        workspaceRoot: URL
    ) async throws -> AnyTool {
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: source,
            jailRoot: workspaceRoot.path,
            toolContextTimeline: ToolTimelineContext(),
            runtimeToolPolicy: .default,
            timelineStore: timelineStore,
            messageStore: messageStore
        )
        return try #require(await toolManager.getAvailableTools().first { $0.callName == "timeline_send" })
    }

    @Test("Refuses to send when source history is already at the remote-depth limit")
    func enforcesRemoteDepthFromSourceHistory() async throws {
        let workspace = TestWorkspace()
        let messageStore = InMemoryMessageStore()
        let timelineStore = InMemoryTimelinePersistence()

        let agentId = UUID()
        let source = Timeline(workingDirectory: workspace.root.path, attachedAgentInstanceId: agentId)
        try await timelineStore.saveTimeline(source)
        try await messageStore.saveMessage(ConversationMessage(
            timelineId: source.id, role: .system, content: "inbound",
            agentInstanceId: agentId, remoteDepth: ChatEngine.Constants.maxRemoteDepth
        ))

        let destination = Timeline(workingDirectory: workspace.root.path, attachedAgentInstanceId: agentId)
        try await timelineStore.saveTimeline(destination)

        let tool = try await sendTool(
            timelineStore: timelineStore, messageStore: messageStore,
            source: source, workspaceRoot: workspace.root
        )
        let result = try await tool.execute(parameters: [
            "timeline_id": AnyCodable(destination.id.uuidString),
            "message": "should be blocked",
        ])

        #expect(!result.success)
        #expect(result.error?.contains("Remote depth limit") == true)
    }

    @Test("Stamps an incremented remote depth derived from source history")
    func stampsIncrementedDepthFromSourceHistory() async throws {
        let workspace = TestWorkspace()
        let messageStore = InMemoryMessageStore()
        let timelineStore = InMemoryTimelinePersistence()

        let agentId = UUID()
        let source = Timeline(workingDirectory: workspace.root.path, attachedAgentInstanceId: agentId)
        try await timelineStore.saveTimeline(source)
        // Source already sits one hop deep.
        try await messageStore.saveMessage(ConversationMessage(
            timelineId: source.id, role: .system, content: "inbound",
            agentInstanceId: agentId, remoteDepth: 1
        ))

        let destination = Timeline(workingDirectory: workspace.root.path, attachedAgentInstanceId: agentId)
        try await timelineStore.saveTimeline(destination)

        let tool = try await sendTool(
            timelineStore: timelineStore, messageStore: messageStore,
            source: source, workspaceRoot: workspace.root
        )
        let result = try await tool.execute(parameters: [
            "timeline_id": AnyCodable(destination.id.uuidString),
            "message": "carry the chain forward",
        ])

        #expect(result.success)
        let delivered = try await messageStore.fetchMessages(for: destination.id)
        #expect(delivered.count == 1)
        #expect(delivered.first?.remoteDepth == 2)
    }
}
