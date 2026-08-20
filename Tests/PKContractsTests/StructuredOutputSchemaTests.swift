import Foundation
import Testing
import struct JSONSchema.Schema
@testable import PKContracts

@Suite("Structured Output Schema Tests")
struct StructuredOutputSchemaTests {
    @Test("Stores JSONSchema primitives directly")
    func storesJSONSchemaPrimitivesDirectly() throws {
        let schema = try Schema(instance: #"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"required":["tags"]}"#)

        let structuredSchema = StructuredOutputSchema(
            name: "tag_payload",
            schema: schema
        )

        let encoded = try JSONEncoder().encode(structuredSchema.schema)
        let encodedString = String(decoding: encoded, as: UTF8.self)

        #expect(encodedString.contains("\"type\":\"object\""))
        #expect(encodedString.contains("\"tags\""))
    }
}

@Suite("LLM Tool Call Recovery State Tests")
struct LLMToolCallRecoveryStateTests {
    @Test("recovery state tracks yielded content and streamed tool calls")
    func recoveryStateTracksObservedStreamSignals() {
        var state = LLMToolCallRecoveryState()

        #expect(state.shouldRetryAfterError)
        #expect(!state.shouldRecoverToolCalls)

        state.observe(yieldedContent: true, streamedToolCalls: false, finishedWithToolCalls: false)
        #expect(!state.shouldRetryAfterError)
        #expect(!state.shouldRecoverToolCalls)

        state.observe(yieldedContent: false, streamedToolCalls: true, finishedWithToolCalls: true)
        #expect(state.finishedWithToolCalls)
        #expect(state.sawStreamedToolCalls)
        #expect(!state.shouldRecoverToolCalls)
    }

    @Test("recovery state requests recovery only when finish reason arrives without streamed tool calls")
    func recoveryStateRequestsRecoveryOnlyWhenNeeded() {
        var state = LLMToolCallRecoveryState()

        state.observe(yieldedContent: false, streamedToolCalls: false, finishedWithToolCalls: true)

        #expect(state.finishedWithToolCalls)
        #expect(!state.sawStreamedToolCalls)
        #expect(state.shouldRecoverToolCalls)
        #expect(state.shouldRetryAfterError)
    }
}
