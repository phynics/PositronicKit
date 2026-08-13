import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import struct PositronicKit.Thread
import Testing

/// Regression coverage for the cross-agent `thread_send` recursion guard.
///
/// The guard previously never fired: `createToolManager` always built `ThreadSendTool` with a
/// hardcoded depth of 0, so every send was treated as the first hop regardless of how deep the
/// source thread's history already was. The tool must derive its current depth from the source
/// thread's message history instead.
///
/// Post-PKARCH-003: tests build tools via `RuntimeToolPolicyFactory` directly, with the same
/// stores the original `ThreadManager.createToolManager` used, so `ThreadManager` is no longer
/// exercised in this single-tool regression suite.
@Suite("Thread Send Tool")
struct ThreadSendToolTests {
    @Test("canonical send tool preserves the external call name")
    func canonicalSendToolPreservesCallName() {
        let tool = ThreadSendTool(
            messageStore: InMemoryMessageStore(),
            threadStore: InMemoryThreadPersistence(),
            agentInstanceID: UUID(),
            sourceThreadID: UUID()
        )

        #expect(tool.callName == "timeline_send")
    }

    private func sendTool(
        threadStore: InMemoryThreadPersistence,
        messageStore: InMemoryMessageStore,
        source: Thread,
        workspaceRoot: URL
    ) async throws -> AnyTool {
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: source,
            jailRoot: workspaceRoot.path,
            runtimeToolPolicy: .default,
            threadStore: threadStore,
            messageStore: messageStore
        )
        return try #require(await toolManager.getAvailableTools().first { $0.callName == "timeline_send" })
    }

    @Test("Refuses to send when source history is already at the remote-depth limit")
    func enforcesRemoteDepthFromSourceHistory() async throws {
        let workspace = TestWorkspace()
        let messageStore = InMemoryMessageStore()
        let threadStore = InMemoryThreadPersistence()

        let agentId = UUID()
        let source = Thread(workingDirectory: workspace.root.path, attachedAgentInstanceID: agentId)
        try await threadStore.saveThread(source)
        try await messageStore.saveMessage(ConversationMessage(
            threadID: source.id, role: .system, content: "inbound",
            agentInstanceID: agentId, remoteDepth: ChatEngine.Constants.maxRemoteDepth
        ))

        let destination = Thread(workingDirectory: workspace.root.path, attachedAgentInstanceID: agentId)
        try await threadStore.saveThread(destination)

        let tool = try await sendTool(
            threadStore: threadStore, messageStore: messageStore,
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
        let threadStore = InMemoryThreadPersistence()

        let agentId = UUID()
        let source = Thread(workingDirectory: workspace.root.path, attachedAgentInstanceID: agentId)
        try await threadStore.saveThread(source)
        // Source already sits one hop deep.
        try await messageStore.saveMessage(ConversationMessage(
            threadID: source.id, role: .system, content: "inbound",
            agentInstanceID: agentId, remoteDepth: 1
        ))

        let destination = Thread(workingDirectory: workspace.root.path, attachedAgentInstanceID: agentId)
        try await threadStore.saveThread(destination)

        let tool = try await sendTool(
            threadStore: threadStore, messageStore: messageStore,
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
