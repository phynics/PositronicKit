import Foundation
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKRR-006: Turn input persistence is deferred until history validation, context gathering,
/// workspace lookup, and prompt assembly all succeed. The `sendId` is an in-memory
/// idempotency key — a second call with the same `sendId` is rejected. Tool-output batches
/// are resumable: already-persisted outputs are skipped on retry.
@Suite("Turn preparation idempotency and atomicity (PKRR-006)")
struct TurnPreparationIdempotencyTests {

    private func drain(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws {
        for try await _ in stream {}
    }

    private func pendingToolCallsJSON(ids: [String]) throws -> String {
        let calls = ids.map { ToolCall(id: $0, name: "external_tool", arguments: [:]) }
        let data = try SerializationUtils.jsonEncoder.encode(calls)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeKit(
        llm: MockLLMService = MockLLMService(),
        messageStore: (any MessageStoreProtocol)? = nil,
        timelineStore: (any TimelinePersistenceProtocol)? = nil,
        workspaceStore: (any WorkspaceStore)? = nil,
        toolPersistence: (any ToolPersistenceProtocol)? = nil
    ) -> (PositronicKit, MockPersistenceService, MockLLMService) {
        let persistence = MockPersistenceService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                messageStore: messageStore ?? persistence,
                timelinePersistence: timelineStore ?? persistence,
                workspacePersistence: workspaceStore ?? persistence,
                memoryStore: persistence,
                toolPersistence: toolPersistence ?? persistence,
                agentInstanceStore: persistence,
                requestOriginStore: persistence
            )
        ))
        return (kit, persistence, llm)
    }

    private func setupTimeline(
        on persistence: MockPersistenceService,
        timelineManager: TimelineManager
    ) async throws -> UUID {
        let timelineId = UUID()
        try await persistence.saveTimeline(Timeline(id: timelineId, title: "PKRR-006 Test"))
        try await timelineManager.hydrateTimeline(id: timelineId)
        return timelineId
    }

    // MARK: - AC: History validation failure leaves no new persisted input

    @Test("Dangling tool call in history prevents user message persistence")
    func danglingToolCallPreventsUserMessagePersistence() async throws {
        let (kit, persistence, _) = makeKit()
        let timelineId = try await setupTimeline(on: persistence, timelineManager: kit.timelineManager)

        try await persistence.saveMessage(ConversationMessage(
            timelineId: timelineId,
            role: .assistant,
            content: "",
            toolCalls: pendingToolCallsJSON(ids: ["dangling_call"])
        ))

        do {
            _ = try await kit.run(ChatRunRequest(
                timelineId: timelineId,
                message: "Follow up"
            ))
            Issue.record("Expected danglingToolCall error")
        } catch is ChatEngineError {
            // Expected
        } catch {
            Issue.record("Expected ChatEngineError, got \(error)")
        }

        let messages = try await persistence.fetchMessages(for: timelineId)
        let userMessages = messages.filter { $0.role == "user" }
        #expect(userMessages.isEmpty, "No user message should be persisted when history validation fails")
    }

    // MARK: - AC: Retrying the same sendId cannot duplicate user or tool messages

    @Test("Retrying the same sendId is rejected as duplicate")
    func retryingSameSendIdIsRejected() async throws {
        let (kit, persistence, llm) = makeKit()
        let timelineId = try await setupTimeline(on: persistence, timelineManager: kit.timelineManager)
        llm.mockClient.nextResponse = "Reply"

        let sendId = UUID()
        let stream = try await kit.run(ChatRunRequest(
            timelineId: timelineId,
            sendId: sendId,
            message: "First turn"
        ))
        try await drain(stream)

        do {
            _ = try await kit.run(ChatRunRequest(
                timelineId: timelineId,
                sendId: sendId,
                message: "Retry"
            ))
            Issue.record("Expected duplicateSendId error")
        } catch let error as ChatEngineError {
            #expect(error.errorCode == 9006)
        } catch {
            Issue.record("Expected ChatEngineError.duplicateSendId, got \(error)")
        }

        let messages = try await persistence.fetchMessages(for: timelineId)
        let userMessages = messages.filter { $0.role == "user" }
        #expect(userMessages.count == 1, "Retrying the same sendId should not duplicate the user message")
        #expect(userMessages.first?.content == "First turn")
    }

    // MARK: - AC: Failed turn releases sendId for retry

    @Test("Failed turn releases sendId so retry with the same sendId succeeds")
    func failedTurnReleasesSendIdForRetry() async throws {
        let (kit, persistence, llm) = makeKit()
        let timelineId = try await setupTimeline(on: persistence, timelineManager: kit.timelineManager)

        try await persistence.saveMessage(ConversationMessage(
            timelineId: timelineId,
            role: .assistant,
            content: "",
            toolCalls: pendingToolCallsJSON(ids: ["call_1"])
        ))

        let sendId = UUID()

        do {
            _ = try await kit.run(ChatRunRequest(
                timelineId: timelineId,
                sendId: sendId,
                message: "Follow up"
            ))
            Issue.record("Expected danglingToolCall error")
        } catch is ChatEngineError {
            // Expected — validation fails, sendId is released
        } catch {
            Issue.record("Expected ChatEngineError, got \(error)")
        }

        let messagesAfterFirst = try await persistence.fetchMessages(for: timelineId)
        #expect(messagesAfterFirst.filter { $0.role == "user" }.isEmpty,
                "No user message should be persisted after a failed turn")

        try await persistence.saveMessage(ConversationMessage(
            timelineId: timelineId,
            role: .tool,
            content: "tool result",
            toolCallId: "call_1"
        ))

        llm.mockClient.nextResponse = "Reply after fix"

        let stream = try await kit.run(ChatRunRequest(
            timelineId: timelineId,
            sendId: sendId,
            message: "Follow up"
        ))
        try await drain(stream)

        let messagesAfterRetry = try await persistence.fetchMessages(for: timelineId)
        let userMessages = messagesAfterRetry.filter { $0.role == "user" }
        #expect(userMessages.count == 1, "Retry with the same sendId should persist exactly one user message")
        #expect(userMessages.first?.content == "Follow up")
    }

    // MARK: - AC: A failed tool-output batch is safely resumable

    @Test("Tool-output batch is resumable after partial failure")
    func toolOutputBatchIsResumableAfterPartialFailure() async throws {
        let batchStore = BatchFailingMessageStore()
        let (kit, persistence, llm) = makeKit(messageStore: batchStore)
        let timelineId = try await setupTimeline(on: persistence, timelineManager: kit.timelineManager)

        try await batchStore.saveMessage(ConversationMessage(
            timelineId: timelineId,
            role: .assistant,
            content: "",
            toolCalls: pendingToolCallsJSON(ids: ["call_1", "call_2", "call_3"])
        ))

        batchStore.failAfterSaveCount = 2

        let sendId = UUID()

        do {
            _ = try await kit.run(ChatRunRequest(
                timelineId: timelineId,
                sendId: sendId,
                message: "",
                toolOutputs: [
                    ToolOutputSubmission(toolCallId: "call_1", output: "result_1"),
                    ToolOutputSubmission(toolCallId: "call_2", output: "result_2"),
                    ToolOutputSubmission(toolCallId: "call_3", output: "result_3"),
                ]
            ))
            Issue.record("Expected save failure")
        } catch {
            // Expected — the batch failed partway through
        }

        let messagesAfterFirst = batchStore.messages.filter { $0.timelineId == timelineId }
        let toolMessagesAfterFirst = messagesAfterFirst.filter { $0.role == "tool" }
        #expect(toolMessagesAfterFirst.count == 1, "First tool output should be persisted (partial batch)")
        #expect(toolMessagesAfterFirst.first?.toolCallId == "call_1")

        batchStore.failAfterSaveCount = nil
        llm.mockClient.nextResponse = "Done"

        let stream = try await kit.run(ChatRunRequest(
            timelineId: timelineId,
            sendId: sendId,
            message: "",
            toolOutputs: [
                ToolOutputSubmission(toolCallId: "call_1", output: "result_1"),
                ToolOutputSubmission(toolCallId: "call_2", output: "result_2"),
                ToolOutputSubmission(toolCallId: "call_3", output: "result_3"),
            ]
        ))
        try await drain(stream)

        let messagesAfterRetry = batchStore.messages.filter { $0.timelineId == timelineId }
        let toolMessagesAfterRetry = messagesAfterRetry.filter { $0.role == "tool" }
        #expect(toolMessagesAfterRetry.count == 3, "All three tool outputs should be persisted after retry (no duplication)")

        let toolCallIds = Set(toolMessagesAfterRetry.compactMap { $0.toolCallId })
        #expect(toolCallIds == ["call_1", "call_2", "call_3"],
                "Tool outputs should contain exactly call_1, call_2, call_3 — no duplicates")
    }

    // MARK: - AC: Retrying the same sendId cannot duplicate tool messages

    @Test("Successful tool-output turn blocks duplicate retry with the same sendId")
    func successfulToolOutputTurnBlocksDuplicateRetry() async throws {
        let (kit, persistence, llm) = makeKit()
        let timelineId = try await setupTimeline(on: persistence, timelineManager: kit.timelineManager)

        try await persistence.saveMessage(ConversationMessage(
            timelineId: timelineId,
            role: .assistant,
            content: "",
            toolCalls: pendingToolCallsJSON(ids: ["call_1"])
        ))

        llm.mockClient.nextResponse = "Done"

        let sendId = UUID()
        let stream = try await kit.run(ChatRunRequest(
            timelineId: timelineId,
            sendId: sendId,
            message: "",
            toolOutputs: [ToolOutputSubmission(toolCallId: "call_1", output: "result_1")]
        ))
        try await drain(stream)

        do {
            _ = try await kit.run(ChatRunRequest(
                timelineId: timelineId,
                sendId: sendId,
                message: "",
                toolOutputs: [ToolOutputSubmission(toolCallId: "call_1", output: "duplicate")]
            ))
            Issue.record("Expected duplicateSendId error")
        } catch let error as ChatEngineError {
            #expect(error.errorCode == 9006)
        } catch {
            Issue.record("Expected ChatEngineError.duplicateSendId, got \(error)")
        }

        let messages = try await persistence.fetchMessages(for: timelineId)
        let toolMessages = messages.filter { $0.role == "tool" && $0.toolCallId == "call_1" }
        #expect(toolMessages.count == 1, "Tool output should not be duplicated on retry")
    }
}
