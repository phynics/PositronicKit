import Foundation
import struct JSONSchema.Schema
@testable import PKContracts
import Testing

/// Direct coverage for `PromptAugmentedJSONSchemaAdapter`.
///
/// This adapter prepares structured-output requests by augmenting the final user message
/// with the schema text and emitting a `json_schema` response format. It is used by
/// OpenAI-compatible and Ollama providers. Tests drive both the `.jsonObject` and
/// `.jsonSchema` branches directly.
@Suite("Prompt-augmented JSON schema structured output adapter")
struct PromptAugmentedJSONSchemaAdapterTests {

    private let baseMessages: [LLMMessage] = [
        LLMMessage(role: .system, content: "You are helpful."),
        LLMMessage(role: .user, content: "Extract the tags."),
    ]

    private let baseTools: [LLMToolDefinition] = [
        LLMToolDefinition(name: "search", description: "Search the web"),
    ]

    private func makeSchema() throws -> StructuredOutputSchema {
        let schema = try Schema(instance: #"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"required":["tags"]}"#)
        return StructuredOutputSchema(
            name: "tag_result",
            description: "Extracted tags",
            schema: schema,
            strict: true
        )
    }

    @Test("jsonObject request sets responseFormat to jsonObject and leaves messages untouched")
    func jsonObjectRequest() {
        let adapter = PromptAugmentedJSONSchemaAdapter()
        let prepared = adapter.prepareRequest(
            messages: baseMessages,
            tools: baseTools,
            output: .jsonObject
        )

        #expect(prepared.messages == baseMessages)
        #expect(prepared.tools?.count == 1)
        #expect(prepared.toolChoice == nil)
        #expect(prepared.responseFormat == .jsonObject)
        #expect(prepared.syntheticToolName == nil)
        #expect(prepared.promptAugmentation == nil)
    }

    @Test("jsonObject request works with nil tools")
    func jsonObjectRequestNilTools() {
        let adapter = PromptAugmentedJSONSchemaAdapter()
        let prepared = adapter.prepareRequest(
            messages: baseMessages,
            tools: nil,
            output: .jsonObject
        )

        #expect(prepared.tools == nil)
        #expect(prepared.responseFormat == .jsonObject)
    }

    @Test("jsonSchema request augments the prompt and sets responseFormat to jsonSchema")
    func jsonSchemaRequest() throws {
        let adapter = PromptAugmentedJSONSchemaAdapter()
        let schema = try makeSchema()

        let prepared = adapter.prepareRequest(
            messages: baseMessages,
            tools: baseTools,
            output: .jsonSchema(schema)
        )

        #expect(prepared.messages.last?.content.contains("tag_result") == true)
        #expect(prepared.promptAugmentation?.contains("JSON Schema") == true)

        #expect(prepared.tools?.count == 1)
        #expect(prepared.toolChoice == nil)
        #expect(prepared.syntheticToolName == nil)

        guard case let .jsonSchema(responseSchema)? = prepared.responseFormat else {
            Issue.record("Expected .jsonSchema response format"); return
        }
        #expect(responseSchema.name == "tag_result")
        #expect(responseSchema.description == "Extracted tags")
        #expect(responseSchema.strict == true)
    }

    @Test("jsonSchema request works with nil tools")
    func jsonSchemaRequestNilTools() throws {
        let adapter = PromptAugmentedJSONSchemaAdapter()
        let schema = try makeSchema()

        let prepared = adapter.prepareRequest(
            messages: baseMessages,
            tools: nil,
            output: .jsonSchema(schema)
        )

        #expect(prepared.tools == nil)
        #expect(prepared.responseFormat != nil)
        #expect(prepared.promptAugmentation != nil)
    }

    @Test("jsonSchema request with no description still augments the prompt")
    func jsonSchemaRequestNoDescription() throws {
        let adapter = PromptAugmentedJSONSchemaAdapter()
        let schema = try Schema(instance: #"{"type":"object","properties":{"x":{"type":"number"}},"required":["x"]}"#)
        let outputSchema = StructuredOutputSchema(
            name: "numbers",
            description: nil,
            schema: schema,
            strict: false
        )

        let prepared = adapter.prepareRequest(
            messages: baseMessages,
            tools: nil,
            output: .jsonSchema(outputSchema)
        )

        #expect(prepared.messages.last?.content.contains("numbers") == true)
        guard case let .jsonSchema(responseSchema)? = prepared.responseFormat else {
            Issue.record("Expected .jsonSchema response format"); return
        }
        #expect(responseSchema.name == "numbers")
        #expect(responseSchema.description == nil)
        #expect(responseSchema.strict == false)
    }
}
