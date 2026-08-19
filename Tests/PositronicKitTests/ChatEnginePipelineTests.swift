import Foundation
import Logging
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

// MARK: - Helpers

private let testLogger = Logger(label: "test.pipeline")

private struct StubTool: PKShared.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    let callName: String
    let name: String
    let description = "Stub"
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()
    func canExecute() async -> Bool {
        true
    }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("ok")
    }
}

private func makeContext(
    fullResponse: String = "",
    toolCallAccumulators: [Int: (id: String, name: String, args: String)] = [:],
    currentMessages: [LLMMessage] = [],
    availableTools: [AnyTool] = []
) async -> ChatTurnContext {
    let outputs = TurnOutputs()
    for chunk in fullResponse {
        await outputs.appendResponse(String(chunk))
    }
    for (index, acc) in toolCallAccumulators {
        await outputs.setToolCallAccumulator(index: index, id: acc.id, name: acc.name, args: acc.args)
    }

    return ChatTurnContext(
        threadID: UUID(),
        agentInstanceId: nil,
        modelName: "test-model",
        maxTurns: 5,
        systemInstructions: nil,
        availableTools: availableTools,
        contextData: ContextData(),
        remoteDepth: 0,
        currentMessages: currentMessages,
        turnCount: 1,
        outputs: outputs
    )
}

private func drain(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private func makeChunk(
    content: String? = nil,
    toolCalls: [LLMToolCallDelta]? = nil,
    finishReason: String? = nil
) -> LLMStreamChunk {
    LLMStreamChunk(
        id: "mock",
        model: "mock-model",
        choices: [LLMStreamChoice(
            index: 0,
            delta: LLMStreamDelta(role: .assistant, content: content, toolCalls: toolCalls),
            finishReason: finishReason
        )]
    )
}

private actor PipelineStageRunTracker {
    private(set) var didRun = false

    func markRan() {
        didRun = true
    }
}

private struct MarkerStage: PipelineStage {
    let tracker: PipelineStageRunTracker

    func process(_: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        await tracker.markRan()
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private actor AggregatingPlugin: ChatTurnPlugin {
    private let suffix: String

    init(suffix: String) {
        self.suffix = suffix
    }

    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage] {
        [LLMMessage(role: .user, content: "\(turn.fullResponse)-\(suffix)")]
    }
}

// MARK: - MessagePersistenceStage Tests

final class MessagePersistenceStageBehavior {
    @Test
    func completedEventEmittedOnFinalTurn() async throws {
        let store = MockPersistenceService()
        let stage = MessagePersistenceStage(messageStore: store, logger: testLogger)
        let context = await makeContext(fullResponse: "Hello!")

        let events = try await drain(await stage.process(context))

        let completions = events.compactMap { $0.completedMessage }
        #expect(completions.count == 1)
        #expect(completions[0].message.content == "Hello!")
    }

    @Test
    func noCompletedEventOnToolCallTurn() async throws {
        let store = MockPersistenceService()
        let stage = MessagePersistenceStage(messageStore: store, logger: testLogger)
        let context = await makeContext(
            toolCallAccumulators: [0: (id: "call-1", name: "my_tool", args: "{}")]
        )

        let events = try await drain(await stage.process(context))

        let completions = events.compactMap { $0.completedMessage }
        #expect(completions.isEmpty)
    }

    @Test
    func turnSnapshotCapturesRenderedPromptOnFinalTurn() async throws {
        let store = MockPersistenceService()
        let stage = MessagePersistenceStage(
            messageStore: store,
            logger: testLogger,
            diagnosticSnapshotConfiguration: .init(policy: .full)
        )
        let context = await makeContext(
            fullResponse: "done",
            currentMessages: [LLMMessage(role: .user, content: "query")]
        )

        let events = try await drain(await stage.process(context))

        let completed = events.compactMap { $0.completedMessage }.first
        let data = try #require(completed?.metadata.turnSnapshotData)
        let snapshot = try SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
        #expect(snapshot.fullResponse == "done")
    }

    @Test("Successful events do not contain diagnostic snapshots by default")
    func defaultPolicyOmitsSnapshot() async throws {
        let stage = MessagePersistenceStage(messageStore: MockPersistenceService(), logger: testLogger)
        let events = try await drain(await stage.process(await makeContext(fullResponse: "private prompt context")))
        let completed = try #require(events.compactMap { $0.completedMessage }.first)

        #expect(completed.metadata.turnSnapshotData == nil)
    }

    @Test("Redacted snapshots mask secrets and obey their byte limit")
    func redactedSnapshotMasksSecretsAndIsBounded() async throws {
        let prompt = "api_key=sk-test-secret password=hunter2 " + String(repeating: "large prompt ", count: 1_000)
        let stage = MessagePersistenceStage(
            messageStore: MockPersistenceService(),
            logger: testLogger,
            diagnosticSnapshotConfiguration: .init(policy: .redacted, maxBytes: 2_000)
        )
        let events = try await drain(await stage.process(await makeContext(
            fullResponse: prompt,
            currentMessages: [LLMMessage(role: .user, content: prompt)]
        )))
        let data = try #require(events.compactMap { $0.completedMessage }.first?.metadata.turnSnapshotData)
        let encoded = try #require(String(data: data, encoding: .utf8))

        #expect(data.count <= 2_000)
        #expect(!encoded.contains("sk-test-secret"))
        #expect(!encoded.contains("hunter2"))
        #expect(encoded.contains("[REDACTED]"))
        #expect(encoded.contains("truncated") || prompt.count < 512)
    }

    @Test("Full snapshots require explicit opt-in and remain bounded")
    func fullSnapshotIsExplicitAndBounded() async throws {
        let stage = MessagePersistenceStage(
            messageStore: MockPersistenceService(),
            logger: testLogger,
            diagnosticSnapshotConfiguration: .init(policy: .full, maxBytes: 1_500)
        )
        let events = try await drain(await stage.process(await makeContext(
            fullResponse: String(repeating: "response ", count: 1_000)
        )))
        let data = try #require(events.compactMap { $0.completedMessage }.first?.metadata.turnSnapshotData)

        #expect(data.count <= 1_500)
    }

    @Test
    func persistedToolCallsPreserveAccumulatedArguments() async throws {
        let store = MockPersistenceService()
        let stage = MessagePersistenceStage(messageStore: store, logger: testLogger)
        let context = await makeContext(
            toolCallAccumulators: [
                0: (
                    id: "call-1",
                    name: "complex_tool",
                    args: #"{"tags":["a","b"],"nested":{"value":1}}"#
                ),
            ]
        )

        _ = try await drain(await stage.process(context))

        #expect(store.messages.count == 1)
        let message = store.messages[0].toMessage()
        #expect(message.toolCalls?.count == 1)
        let toolCall = try #require(message.toolCalls?.first)
        #expect(toolCall.name == "complex_tool")
        let tags = toolCall.arguments["tags"]?.value as? [Any]
        #expect(tags?.count == 2)
        let nested = toolCall.arguments["nested"]?.value as? [String: Any]
        let value = nested?["value"]
        #expect((value as? Int64) == 1 || (value as? UInt64) == 1)
    }

    @Test("Malformed tool-call args fall back to empty arguments (STAB-12)")
    func malformedToolCallArgsFallBackToEmpty() async throws {
        let store = MockPersistenceService()
        let stage = MessagePersistenceStage(messageStore: store, logger: testLogger)
        // Malformed JSON (single quoted key) must not crash the stage; the prior `try? ... ?? [:]`
        // fallback persisted an empty-args tool call. We now also emit a warning — behavior is
        // otherwise unchanged.
        let context = await makeContext(
            toolCallAccumulators: [
                0: (id: "call-bad", name: "broken_tool", args: "{'oops': true}"),
            ]
        )

        _ = try await drain(await stage.process(context))

        #expect(store.messages.count == 1)
        let message = store.messages[0].toMessage()
        #expect(message.toolCalls?.count == 1)
        let toolCall = try #require(message.toolCalls?.first)
        #expect(toolCall.name == "broken_tool")
        #expect(toolCall.id == "call-bad")
        // The empty-args fallback is preserved (decode failed, so no keys leaked in).
        #expect(toolCall.arguments.isEmpty)
    }
}

// MARK: - ChatTurnPipelineBuilder Tests

final class ChatTurnPipelineBuilderTests {
    @Test
    func additionalStagesAreAppendedToDefaultTurnPipeline() async throws {
        let persistence = MockPersistenceService()
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "pipeline"
        let tracker = PipelineStageRunTracker()

        let pipeline = ChatTurnPipelineBuilder.makePipeline(
            llmService: llm,
            messageStore: persistence,
            streamTimeout: 5,
            additionalStages: [MarkerStage(tracker: tracker)]
        )
        let context = await makeContext()

        _ = try await drain(pipeline.execute(context))

        #expect(await tracker.didRun)
        #expect(persistence.messages.last?.content == "pipeline")
    }
}

// MARK: - ChatTurnFollowUpPolicy Tests

final class ChatTurnFollowUpPolicyTests {
    @Test
    func pluginMessagesAggregateAcrossPlugins() async throws {
        let context = await makeContext()
        let messages = try await ChatTurnFollowUpPolicy.pluginMessages(
            for: context,
            turnCount: 2,
            accumulatedOutput: "reply",
            plugins: [AggregatingPlugin(suffix: "one"), AggregatingPlugin(suffix: "two")],
            logger: testLogger
        )

        #expect(messages.map(\.content) == ["reply-one", "reply-two"])
    }

    @Test
    func followUpContinuationRequiresMessagesAndRemainingTurns() {
        #expect(ChatTurnFollowUpPolicy.shouldContinueWithPluginMessages(
            [LLMMessage(role: .user, content: "next")],
            turnCount: 1,
            maxTurns: 2
        ))

        #expect(!ChatTurnFollowUpPolicy.shouldContinueWithPluginMessages(
            [],
            turnCount: 1,
            maxTurns: 2
        ))

        #expect(!ChatTurnFollowUpPolicy.shouldContinueWithPluginMessages(
            [LLMMessage(role: .user, content: "next")],
            turnCount: 2,
            maxTurns: 2
        ))
    }
}

// MARK: - ToolCallExtractionStage Tests

final class ToolCallExtractionStageBehavior {
    @Test
    func sentinelCallsFiltered() async throws {
        let stage = ToolCallExtractionStage(logger: testLogger)
        let context = await makeContext()
        await context.outputs.setToolCallAccumulator(
            index: 0, id: "s1", name: ChatEngine.Constants.sentinelToolName, args: "{}"
        )
        await context.outputs.setToolCallAccumulator(index: 1, id: "r1", name: "real_tool", args: "{}")

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        #expect(accumulators.count == 1)
        #expect(accumulators.values.first?.name == "real_tool")
    }

    @Test
    func emptyNameCallsFiltered() async throws {
        let stage = ToolCallExtractionStage(logger: testLogger)
        let context = await makeContext()
        await context.outputs.setToolCallAccumulator(index: 0, id: "e1", name: "", args: "{}")
        await context.outputs.setToolCallAccumulator(index: 1, id: "k1", name: "valid_tool", args: "{}")

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        #expect(accumulators.count == 1)
        #expect(accumulators.values.first?.name == "valid_tool")
    }

    @Test
    func fallbackTextParsingNoLongerTriggered() async throws {
        let stage = ToolCallExtractionStage(logger: testLogger)
        let tool = StubTool(callName: "test_tool", name: "test_tool")
        let context = await makeContext(
            fullResponse: #"<tool_call>{"name": "test_tool", "arguments": {"key": "val"}}</tool_call>"#,
            availableTools: [tool.toAnyTool()]
        )

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        #expect(accumulators.isEmpty)
    }

    /// YAK-42: emitted records must carry the *raw* threadID as `threadID`
    /// so PositronicKit logs correlate with Yakamoz (YAK-40) logs in Console.app.
    /// Also asserts YAK-37 redaction: no raw tool arguments / secrets leak into metadata.
    @Test
    func emitsRawConversationIDMetadataAndRedactsSecrets() async throws {
        let recorder = MetadataRecorder()
        let logger = Logger(label: "test.pipeline.metadata") { _ in
            RecordingLogHandler(recorder: recorder)
        }
        let stage = ToolCallExtractionStage(logger: logger)

        let threadID = UUID()
        let outputs = TurnOutputs()
        let secretArg = #"{"api_key": "sk-super-secret-payload"}"#
        await outputs.setToolCallAccumulator(index: 0, id: "call-123", name: "lookup", args: secretArg)

        let context = ChatTurnContext(
            threadID: threadID,
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: 5,
            systemInstructions: nil,
            availableTools: [],
            contextData: ContextData(),
            remoteDepth: 0,
            currentMessages: [],
            turnCount: 3,
            outputs: outputs
        )

        _ = try await drain(await stage.process(context))

        let records = recorder.snapshot()
        #expect(!records.isEmpty)

        // threadID must be present and equal to the RAW uuid string (not hashed).
        let threadIDs = records.compactMap { $0["timelineID"] }
        #expect(!threadIDs.isEmpty)
        #expect(threadIDs.allSatisfy { $0 == threadID.uuidString })

        // turnIndex must reflect the turn count.
        let turnIndexes = records.compactMap { $0["turnIndex"] }
        #expect(turnIndexes.contains("3"))

        // toolName is plaintext (an id, not a payload).
        let toolNames = records.compactMap { $0["toolName"] }
        #expect(toolNames.contains("lookup"))

        // YAK-37: no metadata value may contain the raw secret payload.
        for record in records {
            for value in record.values {
                #expect(!value.contains("sk-super-secret-payload"))
                #expect(!value.contains("api_key"))
            }
        }
    }
}

// MARK: - Metadata recording LogHandler (YAK-42)

private final class MetadataRecorder: Sendable {
    private let records = Mutex<[[String: String]]>([])

    func append(_ metadata: [String: String]) {
        records.withLock { $0.append(metadata) }
    }

    func snapshot() -> [[String: String]] {
        records.withLock { $0 }
    }
}

private struct RecordingLogHandler: LogHandler {
    let recorder: MetadataRecorder
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level _: Logger.Level,
        message _: Logger.Message,
        metadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        var merged = self.metadata
        if let metadata {
            merged.merge(metadata) { _, new in new }
        }
        recorder.append(merged.mapValues { "\($0)" })
    }
}

// MARK: - LLMStreamingStage Tests

final class LLMStreamingStageBehavior {
    @Test
    func thinkingAndContentSeparated() async throws {
        let mockService = MockLLMService()
        mockService.mockClient.nextResponse = "<think>reasoning here</think>content here"
        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger, streamTimeout: 5)
        let context = await makeContext()

        let events = try await drain(await stage.process(context))

        let thinking = events.compactMap { $0.reasoningContent }.joined()
        let content = events.compactMap { $0.textContent }.joined()
        #expect(thinking.contains("reasoning here"))
        #expect(content.contains("content here"))
        let fullThinking = await context.outputs.fullThinking
        let fullResponse = await context.outputs.fullResponse
        #expect(fullThinking.contains("reasoning here"))
        #expect(fullResponse.contains("content here"))
    }

    @Test
    func toolCallDeltasEmitted() async throws {
        let mockService = MockLLMService()
        mockService.mockClient.nextResponse = ""
        mockService.mockClient.nextToolCalls = [[
            MockToolCall(id: "tc-1", name: "my_tool", arguments: "{\"x\": 1}"),
        ]]
        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger, streamTimeout: 5)
        let context = await makeContext()

        let events = try await drain(await stage.process(context))

        let toolCallDeltas = events.filter {
            if case .delta(.toolCall) = $0 { return true }
            return false
        }
        #expect(!toolCallDeltas.isEmpty)
        let accumulators = await context.outputs.toolCallAccumulators
        #expect(!accumulators.isEmpty)
    }

    @Test
    func fragmentedToolCallDeltasAccumulateIntoSingleCall() async throws {
        let mockService = MockLLMService()
        mockService.stubbedStream = AsyncThrowingStream { continuation in
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: "tc-1",
                    function: LLMToolCallDeltaFunction(name: "complex_", arguments: "{\"tags\":[")
                ),
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "\"a\",")
                ),
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: nil, arguments: "\"b\"]}")
                ),
            ], finishReason: "tool_calls"))
            continuation.finish()
        }

        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger, streamTimeout: 5)
        let context = await makeContext()

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        let call = try #require(accumulators[0])
        #expect(call.callId == "tc-1")
        #expect(call.name == "complex_tool")
        #expect(call.args == #"{"tags":["a","b"]}"#)
    }

    @Test
    func interleavedMultipleToolCallsPreservePerIndexState() async throws {
        let mockService = MockLLMService()
        mockService.stubbedStream = AsyncThrowingStream { continuation in
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: "tc-1",
                    function: LLMToolCallDeltaFunction(name: "first_", arguments: "{\"x\":")
                ),
                LLMToolCallDelta(
                    index: 1,
                    id: "tc-2",
                    function: LLMToolCallDeltaFunction(name: "second_", arguments: "{\"y\":")
                ),
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 1,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "2}")
                ),
                LLMToolCallDelta(
                    index: 0,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "1}")
                ),
            ], finishReason: "tool_calls"))
            continuation.finish()
        }

        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger, streamTimeout: 5)
        let context = await makeContext()

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        let first = try #require(accumulators[0])
        let second = try #require(accumulators[1])
        #expect(first.callId == "tc-1")
        #expect(first.name == "first_tool")
        #expect(first.args == #"{"x":1}"#)
        #expect(second.callId == "tc-2")
        #expect(second.name == "second_tool")
        #expect(second.args == #"{"y":2}"#)
    }

    @Test
    func toolCallDeltaIdIsBackfilledOnContinuationChunks() async throws {
        let mockService = MockLLMService()
        mockService.stubbedStream = AsyncThrowingStream { continuation in
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: "tc-1",
                    function: LLMToolCallDeltaFunction(name: "complex_", arguments: "{\"tags\":[")
                ),
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "\"a\",")
                ),
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: nil, arguments: "\"b\"]}")
                ),
            ], finishReason: "tool_calls"))
            continuation.finish()
        }

        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger, streamTimeout: 5)
        let context = await makeContext()

        let events = try await drain(await stage.process(context))

        let toolCallDeltas: [ToolCallDelta] = events.compactMap {
            if case let .delta(.toolCall(delta)) = $0 { return delta }
            return nil
        }

        #expect(toolCallDeltas.count == 3)
        for delta in toolCallDeltas {
            #expect(delta.id == "tc-1")
        }

        let argumentsJoined = toolCallDeltas.compactMap(\.arguments).joined()
        #expect(argumentsJoined == #"{"tags":["a","b"]}"#)
    }

    @Test
    func interleavedParallelToolCallDeltasResolveOwnIdsWithoutCrossContamination() async throws {
        let mockService = MockLLMService()
        mockService.stubbedStream = AsyncThrowingStream { continuation in
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: "tc-1",
                    function: LLMToolCallDeltaFunction(name: "first_", arguments: "{\"x\":")
                ),
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 1,
                    id: "tc-2",
                    function: LLMToolCallDeltaFunction(name: "second_", arguments: "{\"y\":")
                ),
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "1}")
                ),
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 1,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "2}")
                ),
            ], finishReason: "tool_calls"))
            continuation.finish()
        }

        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger, streamTimeout: 5)
        let context = await makeContext()

        let events = try await drain(await stage.process(context))

        let toolCallDeltas: [ToolCallDelta] = events.compactMap {
            if case let .delta(.toolCall(delta)) = $0 { return delta }
            return nil
        }

        let index0Deltas = toolCallDeltas.filter { $0.index == 0 }
        let index1Deltas = toolCallDeltas.filter { $0.index == 1 }

        #expect(!index0Deltas.isEmpty)
        #expect(!index1Deltas.isEmpty)
        for delta in index0Deltas {
            #expect(delta.id == "tc-1")
        }
        for delta in index1Deltas {
            #expect(delta.id == "tc-2")
        }
    }
}
