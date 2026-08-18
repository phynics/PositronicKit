import Foundation
import PKTestSupport
import PKShared
import PKUtilities
import Testing
@testable import PositronicKit

@Suite("Structured output synthetic tool stream parsing")
@MainActor
struct StructuredOutputSyntheticToolStreamTests {
    private let syntheticToolName = "emit_structured_response"

    private func chunk(
        content: String = "",
        toolCalls: [LLMToolCallDelta]? = nil,
        finishReason: String? = nil,
        id: String = "chunk-1",
        model: String = "mock-model",
        usage: LLMTokenUsage? = nil
    ) -> LLMStreamChunk {
        LLMStreamChunk(
            id: id,
            model: model,
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(role: .assistant, content: content.isEmpty ? nil : content, toolCalls: toolCalls),
                finishReason: finishReason
            )],
            usage: usage
        )
    }

    private func toolCall(
        name: String,
        arguments: String,
        id: String? = nil,
        index: Int = 0
    ) -> LLMToolCallDelta {
        LLMToolCallDelta(
            index: index,
            id: id,
            function: LLMToolCallDeltaFunction(name: name, arguments: arguments)
        )
    }

    private func stream(_ chunks: [LLMStreamChunk]) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    // MARK: - Synthetic tool rewriting

    @Test("Rewrites a single synthetic tool call into content")
    func rewritesSingleSyntheticToolCall() async throws {
        let input = stream([
            chunk(toolCalls: [toolCall(name: syntheticToolName, arguments: #"{"tags":["swift"]}"#)], finishReason: "tool_calls"),
        ])

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)
        let chunks = try await rewritten.collect()

        #expect(chunks.count == 1)
        #expect(chunks.first?.choices.first?.delta.content == #"{"tags":["swift"]}"#)
        #expect(chunks.first?.choices.first?.delta.toolCalls == nil)
        #expect(chunks.first?.choices.first?.finishReason == "tool_calls")
    }

    @Test("Rewrites fragmented synthetic tool arguments across chunks into per-chunk content")
    func rewritesFragmentedSyntheticToolArgumentsAcrossChunks() async throws {
        let input = stream([
            chunk(toolCalls: [toolCall(name: syntheticToolName, arguments: #"{"tags":["#)]),
            chunk(toolCalls: [toolCall(name: syntheticToolName, arguments: #""swift"]}"#)], finishReason: "tool_calls"),
        ])

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)
        let chunks = try await rewritten.collect()

        // Rewriting happens per-chunk; the caller concatenates content deltas before decoding.
        #expect(chunks.count == 2)
        #expect(chunks.map { $0.choices.first?.delta.content } == [#"{"tags":["#, #""swift"]}"#])
    }

    @Test("Merges multiple synthetic tool calls in one chunk")
    func mergesMultipleSyntheticToolCallsInOneChunk() async throws {
        let input = stream([
            chunk(toolCalls: [
                toolCall(name: syntheticToolName, arguments: #"{"tags":["#),
                toolCall(name: syntheticToolName, arguments: #""swift"]}"#),
            ], finishReason: "tool_calls"),
        ])

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)
        let chunks = try await rewritten.collect()

        #expect(chunks.count == 1)
        #expect(chunks.first?.choices.first?.delta.content == #"{"tags":["swift"]}"#)
    }

    @Test("Filters out chunks with empty synthetic tool arguments")
    func filtersEmptySyntheticToolArguments() async throws {
        let input = stream([
            chunk(toolCalls: [toolCall(name: syntheticToolName, arguments: "")]),
            chunk(toolCalls: [toolCall(name: syntheticToolName, arguments: #"{"tags":["swift"]}"#)], finishReason: "tool_calls"),
        ])

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)
        let chunks = try await rewritten.collect()

        #expect(chunks.count == 1)
        #expect(chunks.first?.choices.first?.delta.content == #"{"tags":["swift"]}"#)
    }

    @Test("Non-synthetic tool calls pass through unchanged")
    func nonSyntheticToolCallsPassThrough() async throws {
        let toolCalls = [toolCall(name: "lookup_weather", arguments: #"{"city":"Berlin"}"#)]
        let input = stream([
            chunk(toolCalls: toolCalls, finishReason: "tool_calls"),
        ])

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)
        let chunks = try await rewritten.collect()

        #expect(chunks.count == 1)
        #expect(chunks.first?.choices.first?.delta.content == nil)
        #expect(chunks.first?.choices.first?.delta.toolCalls?.count == 1)
        #expect(chunks.first?.choices.first?.delta.toolCalls?.first?.function?.name == "lookup_weather")
    }

    @Test("Mixed synthetic and non-synthetic tool calls preserve both content and tool calls")
    func mixedSyntheticAndNonSyntheticToolCallsInOneChunk() async throws {
        // When a single chunk contains both synthetic and non-synthetic tool calls, the rewriter
        // emits the merged synthetic content first, then a separate chunk carrying the
        // non-synthetic tool-call deltas. Finish reason and usage defer to the trailing
        // non-synthetic chunk so completion and token totals are reported exactly once.
        let input = stream([
            chunk(toolCalls: [
                toolCall(name: "lookup_weather", arguments: #"{"city":"Berlin"}"#),
                toolCall(name: syntheticToolName, arguments: #"{"tags":["swift"]}"#),
            ], finishReason: "tool_calls"),
        ])

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)
        let chunks = try await rewritten.collect()

        #expect(chunks.count == 2)

        let syntheticChunk = chunks[0]
        #expect(syntheticChunk.choices.first?.delta.content == #"{"tags":["swift"]}"#)
        #expect(syntheticChunk.choices.first?.delta.toolCalls == nil)
        #expect(syntheticChunk.choices.first?.finishReason == nil)

        let toolCallChunk = chunks[1]
        #expect(toolCallChunk.choices.first?.delta.content == nil)
        #expect(toolCallChunk.choices.first?.delta.toolCalls?.count == 1)
        #expect(toolCallChunk.choices.first?.delta.toolCalls?.first?.function?.name == "lookup_weather")
        #expect(toolCallChunk.choices.first?.delta.toolCalls?.first?.function?.arguments == #"{"city":"Berlin"}"#)
        #expect(toolCallChunk.choices.first?.finishReason == "tool_calls")
    }

    @Test("Mixed chunk with empty synthetic arguments still preserves non-synthetic tool calls")
    func mixedChunkWithEmptySyntheticArgumentsPreservesNonSyntheticToolCalls() async throws {
        let input = stream([
            chunk(toolCalls: [
                toolCall(name: "lookup_weather", arguments: #"{"city":"Berlin"}"#),
                toolCall(name: syntheticToolName, arguments: ""),
            ], finishReason: "tool_calls"),
        ])

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)
        let chunks = try await rewritten.collect()

        #expect(chunks.count == 1)
        #expect(chunks.first?.choices.first?.delta.content == nil)
        #expect(chunks.first?.choices.first?.delta.toolCalls?.count == 1)
        #expect(chunks.first?.choices.first?.delta.toolCalls?.first?.function?.name == "lookup_weather")
        #expect(chunks.first?.choices.first?.finishReason == "tool_calls")
    }

    @Test("Preserves id, model, and usage when rewriting")
    func preservesMetadata() async throws {
        let usage = LLMTokenUsage(
            promptTokens: 10,
            completionTokens: 5,
            totalTokens: 15,
            promptTokensDetails: nil
        )
        let input = stream([
            chunk(
                toolCalls: [toolCall(name: syntheticToolName, arguments: #"{"tags":["swift"]}"#)],
                finishReason: "tool_calls",
                id: "or-123",
                model: "openai/gpt-4o",
                usage: usage
            ),
        ])

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)
        let chunks = try await rewritten.collect()

        #expect(chunks.first?.id == "or-123")
        #expect(chunks.first?.model == "openai/gpt-4o")
        #expect(chunks.first?.usage?.totalTokens == 15)
    }

    @Test("Propagates upstream errors")
    func propagatesUpstreamErrors() async {
        let input = AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
            continuation.finish(throwing: NSError(domain: "test", code: 1))
        }

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)

        await #expect(throws: (any Error).self) {
            _ = try await rewritten.collect()
        }
    }

    @Test("Plain content chunks pass through unchanged")
    func plainContentChunksPassThrough() async throws {
        let input = stream([
            chunk(content: "hello", finishReason: "stop"),
        ])

        let rewritten = StructuredOutputExecution.rewriteSyntheticToolStream(input, syntheticToolName: syntheticToolName)
        let chunks = try await rewritten.collect()

        #expect(chunks.count == 1)
        #expect(chunks.first?.choices.first?.delta.content == "hello")
        #expect(chunks.first?.choices.first?.finishReason == "stop")
    }

    // MARK: - End-to-end through LLMService

    @Test("End-to-end synthetic tool response is decoded as typed structured output")
    func endToEndSyntheticToolResponseDecodes() async throws {
        struct TagPayload: Decodable, Equatable {
            let tags: [String]
        }

        let mockClient = MockLLMClient()
        mockClient.nextToolCalls = [[MockToolCall(id: "structured-call", name: syntheticToolName, arguments: #"{"tags":["swift"]}"#)]]

        mockClient.structuredOutputAdapter = DefaultStructuredOutputAdapter()
        let service = LLMService(storage: MockConfigurationService(), client: mockClient)
        try await service.updateConfiguration(.fixture(activeProvider: .anthropic))
        await service.setClients(main: mockClient, utility: nil, fast: nil)

        let result = try await service.sendStructured(
            "Extract tags",
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition()),
            as: TagPayload.self
        )

        #expect(result == TagPayload(tags: ["swift"]))
    }

    @Test("End-to-end fragmented synthetic tool response is decoded as typed structured output")
    func endToEndFragmentedSyntheticToolResponseDecodes() async throws {
        struct TagPayload: Decodable, Equatable {
            let tags: [String]
        }

        let mockClient = MockLLMClient()
        mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(id: "structured-call", name: syntheticToolName, arguments: "{" + #""tags":["#)
            ]),
            ChatStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(id: "structured-call", name: syntheticToolName, arguments: #""swift"]}"#)
            ]),
        ]]

        mockClient.structuredOutputAdapter = DefaultStructuredOutputAdapter()
        let service = LLMService(storage: MockConfigurationService(), client: mockClient)
        try await service.updateConfiguration(.fixture(activeProvider: .anthropic))
        await service.setClients(main: mockClient, utility: nil, fast: nil)

        let result = try await service.sendStructured(
            "Extract tags",
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition()),
            as: TagPayload.self
        )

        #expect(result == TagPayload(tags: ["swift"]))
    }
}
