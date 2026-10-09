import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Regression coverage for the cross-agent `thread_send` recursion guard.
///
/// The guard previously never fired: `createToolManager` always built `TimelineSendTool` with a
/// hardcoded depth of 0, so every send was treated as the first hop regardless of how deep the
/// source timeline's history already was. The tool must derive its current depth from the source
/// timeline's message history instead.
///
/// Post-PKARCH-003: tests build tools via `RuntimeToolPolicyFactory` directly, with the same
/// stores the original `TimelineManager.createToolManager` used, so `TimelineManager` is no longer
/// exercised in this single-tool regression suite.
@Suite("Timeline Send PKTool", .tags(.integration))
struct TimelineSendToolTests {
    @Test("canonical send tool preserves the external call name")
    func canonicalSendToolPreservesCallName() {
        let tool = TimelineSendTool(
            messageStore: InMemoryMessageStore(),
            timelineStore: InMemoryTimelinePersistence(),
            agentID: UUID(),
            sourceTimelineID: UUID()
        )

        #expect(tool.callName == "thread_send")
    }

    private func sendTool(
        timelineStore: InMemoryTimelinePersistence,
        messageStore: any TimelineMessageStoreProtocol,
        source: TimelineRecord,
        workspaceRoot: URL
    ) async throws -> AnyTool {
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: source,
            jailRoot: workspaceRoot.path,
            runtimeToolPolicy: .default,
            timelineStore: timelineStore,
            messageStore: messageStore
        )
        return try #require(await toolManager.getAvailableTools().first { $0.callName == "thread_send" })
    }

    @Test("Refuses to send when source history is already at the remote-depth limit")
    func enforcesRemoteDepthFromSourceHistory() async throws {
        let workspace = TestWorkspace()
        let messageStore = InMemoryMessageStore()
        let timelineStore = InMemoryTimelinePersistence()

        let agentId = UUID()
        let source = TimelineRecord(workingDirectory: workspace.root.path, attachedAgentID: agentId)
        try await timelineStore.saveTimeline(source)
        try await messageStore.saveMessage(TimelineMessage(
            timelineID: source.id, role: .system, content: "inbound",
            agentID: agentId, remoteDepth: TurnEngine.Constants.maxRemoteDepth
        ))

        let destination = TimelineRecord(workingDirectory: workspace.root.path, attachedAgentID: agentId)
        try await timelineStore.saveTimeline(destination)

        let tool = try await sendTool(
            timelineStore: timelineStore, messageStore: messageStore,
            source: source, workspaceRoot: workspace.root
        )
        let result = try await tool.execute(parameters: [
            "thread_id": AnyCodable(destination.id.uuidString),
            "message": "should be blocked",
        ])

        #expect(!result.isSuccess)
        #expect(result.error?.contains("Remote depth limit") == true)
    }

    @Test("Does not send when source history cannot be read")
    func sourceHistoryReadFailureDoesNotSend() async throws {
        let workspace = TestWorkspace()
        let timelineStore = InMemoryTimelinePersistence()
        let backing = InMemoryMessageStore()
        let agentID = UUID()
        let source = TimelineRecord(workingDirectory: workspace.root.path, attachedAgentID: agentID)
        let destination = TimelineRecord(workingDirectory: workspace.root.path, attachedAgentID: agentID)
        try await timelineStore.saveTimeline(source)
        try await timelineStore.saveTimeline(destination)
        let existingMessage = TimelineMessage(timelineID: destination.id, role: .system, content: "existing")
        try await backing.saveMessage(existingMessage)
        let messageStore = HistoryReadFailingMessageStore(sourceTimelineID: source.id, backing: backing)
        let tool = try await sendTool(
            timelineStore: timelineStore, messageStore: messageStore,
            source: source, workspaceRoot: workspace.root
        )

        let result = try await tool.execute(parameters: [
            "thread_id": AnyCodable(destination.id.uuidString),
            "message": "must not be delivered",
        ])

        #expect(!result.isSuccess)
        #expect(result.error == "Could not read source timeline history. Message was not sent.")
        #expect(await messageStore.readTimelineIDs == [source.id])
        #expect(await messageStore.saveCount == 0)
        let delivered = try await backing.fetchMessages(for: destination.id)
        #expect(delivered.map(\.id) == [existingMessage.id])
    }

    @Test("Stamps the next depth for empty and existing source history", arguments: [0, 1])
    func stampsIncrementedDepthFromSourceHistory(existingRemoteDepth: Int) async throws {
        let workspace = TestWorkspace()
        let messageStore = InMemoryMessageStore()
        let timelineStore = InMemoryTimelinePersistence()

        let agentId = UUID()
        let source = TimelineRecord(workingDirectory: workspace.root.path, attachedAgentID: agentId)
        try await timelineStore.saveTimeline(source)
        if existingRemoteDepth > 0 {
            try await messageStore.saveMessage(TimelineMessage(
                timelineID: source.id, role: .system, content: "inbound",
                agentID: agentId, remoteDepth: existingRemoteDepth
            ))
        }

        let destination = TimelineRecord(workingDirectory: workspace.root.path, attachedAgentID: agentId)
        try await timelineStore.saveTimeline(destination)

        let tool = try await sendTool(
            timelineStore: timelineStore, messageStore: messageStore,
            source: source, workspaceRoot: workspace.root
        )
        let result = try await tool.execute(parameters: [
            "thread_id": AnyCodable(destination.id.uuidString),
            "message": "carry the chain forward",
        ])

        #expect(result.isSuccess)
        let delivered = try await messageStore.fetchMessages(for: destination.id)
        #expect(delivered.count == 1)
        #expect(delivered.first?.remoteDepth == existingRemoteDepth + 1)
    }
}

private actor HistoryReadFailingMessageStore: TimelineMessageStoreProtocol {
    private let sourceTimelineID: UUID
    private let backing: InMemoryMessageStore
    private(set) var readTimelineIDs: [UUID] = []
    private(set) var saveCount = 0

    init(sourceTimelineID: UUID, backing: InMemoryMessageStore) {
        self.sourceTimelineID = sourceTimelineID
        self.backing = backing
    }

    func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        readTimelineIDs.append(timelineID)
        if timelineID == sourceTimelineID { throw FailingStoreError.fetchFailed }
        return try await backing.fetchMessages(for: timelineID)
    }

    func saveMessage(_ message: TimelineMessage) async throws {
        saveCount += 1
        try await backing.saveMessage(message)
    }

    func deleteMessages(for timelineID: UUID) async throws {
        try await backing.deleteMessages(for: timelineID)
    }

    func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        try await backing.pruneMessages(olderThan: timeInterval, dryRun: dryRun)
    }

    func fetchSnapshots(for timelineID: UUID) async throws -> [TurnSnapshot] {
        try await backing.fetchSnapshots(for: timelineID)
    }
}
