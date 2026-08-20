import Foundation
@testable import PKFoundationModelsProvider
import PKContracts
import PKUtilities
import Testing

/// Unit tests for `FoundationModelsStreamMapper` (PKPOST-003): pure event→`LLMStreamChunk`
/// mapping, with no dependency on the `FoundationModels` framework or a live session — the
/// input is a scripted `FoundationModelsSessionEvent` sequence, matching the ticket's
/// requirement that the mapping layer be unit-testable without live Apple Intelligence.
@Suite("FoundationModels stream mapping")
struct FoundationModelsStreamMapperTests {
    @Test("Text deltas map to content chunks in order")
    func textDeltasMapToContentChunks() {
        var state = FoundationModelsStreamMapper.State()
        let events: [FoundationModelsSessionEvent] = [.textDelta("hello "), .textDelta("world")]

        let chunks = events.compactMap {
            FoundationModelsStreamMapper.map($0, model: "apple-on-device", messageID: "msg-1", state: &state)
        }

        #expect(chunks.count == 2)
        let text = chunks.compactMap { $0.choices.first?.delta.content }.joined()
        #expect(text == "hello world")
        #expect(chunks.allSatisfy { $0.id == "msg-1" && $0.model == "apple-on-device" })
    }

    @Test("Empty text deltas produce no chunk")
    func emptyTextDeltaProducesNoChunk() {
        var state = FoundationModelsStreamMapper.State()
        let chunk = FoundationModelsStreamMapper.map(
            .textDelta(""), model: "m", messageID: "id", state: &state
        )
        #expect(chunk == nil)
    }

    @Test("Tool calls carry id, name, arguments, and an assigned ordinal index")
    func toolCallsCarryOrdinal() throws {
        var state = FoundationModelsStreamMapper.State()
        let chunk = FoundationModelsStreamMapper.map(
            .toolCall(id: "call_1", name: "lookup_weather", argumentsJSON: "{\"city\":\"Berlin\"}"),
            model: "m", messageID: "id", state: &state
        )

        let delta = try #require(chunk?.choices.first?.delta)
        let toolCall = try #require(delta.toolCalls?.first)
        #expect(toolCall.index == 0)
        #expect(toolCall.id == "call_1")
        #expect(toolCall.function?.name == "lookup_weather")
        #expect(toolCall.function?.arguments == "{\"city\":\"Berlin\"}")
    }

    @Test("Multiple distinct tool calls get increasing ordinals; repeated ids reuse theirs")
    func multipleToolCallsGetDistinctOrdinals() {
        var state = FoundationModelsStreamMapper.State()

        let first = FoundationModelsStreamMapper.map(
            .toolCall(id: "call_1", name: "a", argumentsJSON: "{}"),
            model: "m", messageID: "id", state: &state
        )
        let second = FoundationModelsStreamMapper.map(
            .toolCall(id: "call_2", name: "b", argumentsJSON: "{}"),
            model: "m", messageID: "id", state: &state
        )
        // Same id as `first` (e.g. streamed arguments in two parts): must reuse ordinal 0.
        let firstAgain = FoundationModelsStreamMapper.map(
            .toolCall(id: "call_1", name: "a", argumentsJSON: "{\"x\":1}"),
            model: "m", messageID: "id", state: &state
        )

        #expect(first?.choices.first?.delta.toolCalls?.first?.index == 0)
        #expect(second?.choices.first?.delta.toolCalls?.first?.index == 1)
        #expect(firstAgain?.choices.first?.delta.toolCalls?.first?.index == 0)
    }

    @Test("Tool output events produce no chunk (framework already executed the tool)")
    func toolOutputProducesNoChunk() {
        var state = FoundationModelsStreamMapper.State()
        let chunk = FoundationModelsStreamMapper.map(
            .toolOutput(id: "call_1", name: "lookup_weather", output: "sunny"),
            model: "m", messageID: "id", state: &state
        )
        #expect(chunk == nil)
    }

    @Test("Finished(.stop) maps to a terminal chunk with finishReason \"stop\"")
    func finishedStopMapsToTerminalChunk() {
        var state = FoundationModelsStreamMapper.State()
        let chunk = FoundationModelsStreamMapper.map(
            .finished(.stop), model: "m", messageID: "id", state: &state
        )
        #expect(chunk?.choices.first?.finishReason == "stop")
    }

    @Test("Finished(.contentFilter) maps to finishReason \"content_filter\" (guardrail refusal)")
    func finishedContentFilterMapsCorrectly() {
        var state = FoundationModelsStreamMapper.State()
        let chunk = FoundationModelsStreamMapper.map(
            .finished(.contentFilter), model: "m", messageID: "id", state: &state
        )
        #expect(chunk?.choices.first?.finishReason == "content_filter")
    }

    @Test("Finished(.length) maps to finishReason \"length\" (context-exceeded)")
    func finishedLengthMapsCorrectly() {
        var state = FoundationModelsStreamMapper.State()
        let chunk = FoundationModelsStreamMapper.map(
            .finished(.length), model: "m", messageID: "id", state: &state
        )
        #expect(chunk?.choices.first?.finishReason == "length")
    }

    @Test("A full multi-tool session maps text, both tool calls, and a stop reason in order")
    func fullMultiToolSessionDecodesToChunks() {
        var state = FoundationModelsStreamMapper.State()
        let events: [FoundationModelsSessionEvent] = [
            .textDelta("Let me check. "),
            .toolCall(id: "call_1", name: "lookup_weather", argumentsJSON: "{\"city\":\"Berlin\"}"),
            .toolOutput(id: "call_1", name: "lookup_weather", output: "Sunny, 22C"),
            .toolCall(id: "call_2", name: "lookup_time", argumentsJSON: "{\"tz\":\"CET\"}"),
            .toolOutput(id: "call_2", name: "lookup_time", output: "14:00"),
            .textDelta("It's sunny and 14:00."),
            .finished(.stop),
        ]

        let chunks = events.compactMap {
            FoundationModelsStreamMapper.map($0, model: "apple-on-device", messageID: "msg-1", state: &state)
        }

        // Two textDelta + two toolCall + one finished = 5 chunks; toolOutput yields none.
        #expect(chunks.count == 5)
        let toolCallChunks = chunks.filter { $0.choices.first?.delta.toolCalls != nil }
        #expect(toolCallChunks.map { $0.choices.first?.delta.toolCalls?.first?.index } == [0, 1])
        #expect(chunks.last?.choices.first?.finishReason == "stop")
    }
}
