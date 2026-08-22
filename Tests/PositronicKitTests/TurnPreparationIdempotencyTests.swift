import Foundation
import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKRR-006: Turn input persistence is deferred until history validation, context gathering,
/// workspace lookup, and prompt assembly all succeed. The `requestId` is an in-memory
/// idempotency key — a second call with the same `requestId` is rejected. Tool-output batches
/// are resumable: already-persisted outputs are skipped on retry.
@Suite("Turn preparation idempotency and atomicity (PKRR-006)")
struct TurnPreparationIdempotencyTests {

    private func drain(_ stream: AsyncThrowingStream<TurnEvent, Error>) async throws {
        for try await _ in stream {}
    }

    private func pendingToolCallsJSON(ids: [String]) throws -> String {
        let calls = ids.map { ToolCall(id: $0, name: "external_tool", arguments: [:]) }
        let data = try SerializationUtils.jsonEncoder.encode(calls)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeKit(
        llm: MockLLMService = MockLLMService(),
        messageStore: (any ThreadMessageStoreProtocol)? = nil,
        threadStore: (any ThreadPersistenceProtocol)? = nil,
        workspaceStore: (any WorkspaceStore)? = nil,
        toolPersistence: (any ToolPersistenceProtocol)? = nil
    ) -> (PositronicKit, MockPersistenceService, MockLLMService) {
        let persistence = MockPersistenceService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                messageStore: messageStore ?? persistence,
                threadPersistence: threadStore ?? persistence,
                workspacePersistence: workspaceStore ?? persistence,
                toolPersistence: toolPersistence ?? persistence,
                agentStore: persistence,
                requestOriginStore: persistence
            )
        ))
        return (kit, persistence, llm)
    }

    private func setupThread(
        on persistence: MockPersistenceService,
        threadManager: ThreadManager
    ) async throws -> UUID {
        let threadID = UUID()
        try await persistence.saveThread(Thread(id: threadID, title: "PKRR-006 Test"))
        try await threadManager.hydrateThread(id: threadID)
        return threadID
    }

    // MARK: - AC: History validation failure leaves no new persisted input

    @Test("Dangling tool call in history prevents user message persistence")
    func danglingToolCallPreventsUserMessagePersistence() async throws {
        let (kit, persistence, _) = makeKit()
        let threadID = try await setupThread(on: persistence, threadManager: kit.threadManager)

        try await persistence.saveMessage(ThreadMessage(
            threadID: threadID,
            role: .assistant,
            content: "",
            toolCalls: pendingToolCallsJSON(ids: ["dangling_call"])
        ))

        do {
            _ = try await kit.run(TurnRequest(
                threadID: threadID,
                message: "Follow up"
            ))
            Issue.record("Expected danglingToolCall error")
        } catch is TurnEngineError {
            // Expected
        } catch {
            Issue.record("Expected TurnEngineError, got \(error)")
        }

        let messages = try await persistence.fetchMessages(for: threadID)
        let userMessages = messages.filter { $0.role == "user" }
        #expect(userMessages.isEmpty, "No user message should be persisted when history validation fails")
    }

    // MARK: - AC: Retrying the same requestId cannot duplicate user or tool messages

    @Test("Retrying the same requestId is rejected as duplicate")
    func retryingSameRequestIDIsRejected() async throws {
        let (kit, persistence, llm) = makeKit()
        let threadID = try await setupThread(on: persistence, threadManager: kit.threadManager)
        llm.mockClient.nextResponse = "Reply"

        let requestId = UUID()
        let stream = try await kit.run(TurnRequest(
            threadID: threadID,
            requestID: requestId,
            message: "First turn"
        ))
        try await drain(stream)

        do {
            _ = try await kit.run(TurnRequest(
                threadID: threadID,
                requestID: requestId,
                message: "Retry"
            ))
            Issue.record("Expected duplicateRequestID error")
        } catch let error as TurnEngineError {
            #expect(error.errorCode == 9006)
        } catch {
            Issue.record("Expected TurnEngineError.duplicateRequestID, got \(error)")
        }

        let messages = try await persistence.fetchMessages(for: threadID)
        let userMessages = messages.filter { $0.role == "user" }
        #expect(userMessages.count == 1, "Retrying the same requestId should not duplicate the user message")
        #expect(userMessages.first?.content == "First turn")
    }

    // MARK: - AC: Failed turn releases requestId for retry

    @Test("Failed turn releases requestId so retry with the same requestId succeeds")
    func failedTurnReleasesRequestIDForRetry() async throws {
        let (kit, persistence, llm) = makeKit()
        let threadID = try await setupThread(on: persistence, threadManager: kit.threadManager)

        try await persistence.saveMessage(ThreadMessage(
            threadID: threadID,
            role: .assistant,
            content: "",
            toolCalls: pendingToolCallsJSON(ids: ["call_1"])
        ))

        let requestId = UUID()

        do {
            _ = try await kit.run(TurnRequest(
                threadID: threadID,
                requestID: requestId,
                message: "Follow up"
            ))
            Issue.record("Expected danglingToolCall error")
        } catch is TurnEngineError {
            // Expected — validation fails, requestId is released
        } catch {
            Issue.record("Expected TurnEngineError, got \(error)")
        }

        let messagesAfterFirst = try await persistence.fetchMessages(for: threadID)
        #expect(messagesAfterFirst.filter { $0.role == "user" }.isEmpty,
                "No user message should be persisted after a failed turn")

        try await persistence.saveMessage(ThreadMessage(
            threadID: threadID,
            role: .tool,
            content: "tool result",
            toolCallID: "call_1"
        ))

        llm.mockClient.nextResponse = "Reply after fix"

        let stream = try await kit.run(TurnRequest(
            threadID: threadID,
            requestID: requestId,
            message: "Follow up"
        ))
        try await drain(stream)

        let messagesAfterRetry = try await persistence.fetchMessages(for: threadID)
        let userMessages = messagesAfterRetry.filter { $0.role == "user" }
        #expect(userMessages.count == 1, "Retry with the same requestId should persist exactly one user message")
        #expect(userMessages.first?.content == "Follow up")
    }

    // MARK: - AC: A failed tool-output batch is safely resumable

    @Test("Tool-output batch is resumable after partial failure")
    func toolOutputBatchIsResumableAfterPartialFailure() async throws {
        let batchStore = BatchFailingMessageStore()
        let (kit, persistence, llm) = makeKit(messageStore: batchStore)
        let threadID = try await setupThread(on: persistence, threadManager: kit.threadManager)

        try await batchStore.saveMessage(ThreadMessage(
            threadID: threadID,
            role: .assistant,
            content: "",
            toolCalls: pendingToolCallsJSON(ids: ["call_1", "call_2", "call_3"])
        ))

        batchStore.failAfterSaveCount = 2

        let requestId = UUID()

        do {
            _ = try await kit.run(TurnRequest(
                threadID: threadID,
                requestID: requestId,
                message: "",
                toolOutputs: [
                    ToolOutputSubmission(toolCallID: "call_1", output: "result_1"),
                    ToolOutputSubmission(toolCallID: "call_2", output: "result_2"),
                    ToolOutputSubmission(toolCallID: "call_3", output: "result_3"),
                ]
            ))
            Issue.record("Expected save failure")
        } catch {
            // Expected — the batch failed partway through
        }

        let messagesAfterFirst = batchStore.messages.filter { $0.threadID == threadID }
        let toolMessagesAfterFirst = messagesAfterFirst.filter { $0.role == "tool" }
        #expect(toolMessagesAfterFirst.count == 1, "First tool output should be persisted (partial batch)")
        #expect(toolMessagesAfterFirst.first?.toolCallID == "call_1")

        batchStore.failAfterSaveCount = nil
        llm.mockClient.nextResponse = "Done"

        let stream = try await kit.run(TurnRequest(
            threadID: threadID,
            requestID: requestId,
            message: "",
            toolOutputs: [
                ToolOutputSubmission(toolCallID: "call_1", output: "result_1"),
                ToolOutputSubmission(toolCallID: "call_2", output: "result_2"),
                ToolOutputSubmission(toolCallID: "call_3", output: "result_3"),
            ]
        ))
        try await drain(stream)

        let messagesAfterRetry = batchStore.messages.filter { $0.threadID == threadID }
        let toolMessagesAfterRetry = messagesAfterRetry.filter { $0.role == "tool" }
        #expect(toolMessagesAfterRetry.count == 3, "All three tool outputs should be persisted after retry (no duplication)")

        let toolCallIds = Set(toolMessagesAfterRetry.compactMap { $0.toolCallID })
        #expect(toolCallIds == ["call_1", "call_2", "call_3"],
                "Tool outputs should contain exactly call_1, call_2, call_3 — no duplicates")
    }

    // MARK: - AC: Retrying the same requestId cannot duplicate tool messages

    @Test("Successful tool-output turn blocks duplicate retry with the same requestId")
    func successfulToolOutputTurnBlocksDuplicateRetry() async throws {
        let (kit, persistence, llm) = makeKit()
        let threadID = try await setupThread(on: persistence, threadManager: kit.threadManager)

        try await persistence.saveMessage(ThreadMessage(
            threadID: threadID,
            role: .assistant,
            content: "",
            toolCalls: pendingToolCallsJSON(ids: ["call_1"])
        ))

        llm.mockClient.nextResponse = "Done"

        let requestId = UUID()
        let stream = try await kit.run(TurnRequest(
            threadID: threadID,
            requestID: requestId,
            message: "",
            toolOutputs: [ToolOutputSubmission(toolCallID: "call_1", output: "result_1")]
        ))
        try await drain(stream)

        do {
            _ = try await kit.run(TurnRequest(
                threadID: threadID,
                requestID: requestId,
                message: "",
                toolOutputs: [ToolOutputSubmission(toolCallID: "call_1", output: "duplicate")]
            ))
            Issue.record("Expected duplicateRequestID error")
        } catch let error as TurnEngineError {
            #expect(error.errorCode == 9006)
        } catch {
            Issue.record("Expected TurnEngineError.duplicateRequestID, got \(error)")
        }

        let messages = try await persistence.fetchMessages(for: threadID)
        let toolMessages = messages.filter { $0.role == "tool" && $0.toolCallID == "call_1" }
        #expect(toolMessages.count == 1, "Tool output should not be duplicated on retry")
    }
}
