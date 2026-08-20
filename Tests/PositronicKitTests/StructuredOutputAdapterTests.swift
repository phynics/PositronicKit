import Foundation
import JSONSchemaBuilder
import PKContracts
import Testing

@Suite("Structured output adapters")
@MainActor
struct StructuredOutputAdapterTests {
    private static let baseMessages = [LLMMessage(role: .user, content: "Extract tags")]
    private static let baseTool = LLMToolDefinition(name: "existing_tool", description: "existing")

    private static func tagSchema() -> StructuredOutputSchema {
        StructuredOutputSchema(
            name: "tag_schema",
            description: "Tag extraction schema",
            schema: JSONString().definition(),
            strict: true
        )
    }

    @Test("OpenAI adapter uses native JSON schema and leaves messages untouched")
    func openAIAdapter() {
        let adapter = NativeJSONSchemaStructuredOutputAdapter()
        let schema = Self.tagSchema()

        let jsonObjectPrepared = adapter.prepareRequest(
            messages: Self.baseMessages,
            tools: [Self.baseTool],
            output: .jsonObject
        )
        #expect(jsonObjectPrepared.messages == Self.baseMessages)
        #expect(jsonObjectPrepared.tools?.count == 1)
        #expect(jsonObjectPrepared.responseFormat == .jsonObject)
        #expect(jsonObjectPrepared.toolChoice == nil)
        #expect(jsonObjectPrepared.syntheticToolName == nil)
        #expect(jsonObjectPrepared.promptAugmentation == nil)

        let jsonSchemaPrepared = adapter.prepareRequest(
            messages: Self.baseMessages,
            tools: [Self.baseTool],
            output: .jsonSchema(schema)
        )
        #expect(jsonSchemaPrepared.messages == Self.baseMessages)
        #expect(jsonSchemaPrepared.tools?.count == 1)
        #expect(jsonSchemaPrepared.syntheticToolName == nil)
        #expect(jsonSchemaPrepared.promptAugmentation == nil)
        guard case let .jsonSchema(responseSchema)? = jsonSchemaPrepared.responseFormat else {
            Issue.record("Expected JSON schema response format")
            return
        }
        #expect(responseSchema.name == schema.name)
        #expect(responseSchema.description == schema.description)
        #expect(responseSchema.strict == schema.strict)
    }

    @Test("OpenRouter adapter behaves like OpenAI native schema")
    func openRouterAdapter() {
        let adapter = NativeJSONSchemaStructuredOutputAdapter()
        let schema = Self.tagSchema()

        let prepared = adapter.prepareRequest(
            messages: Self.baseMessages,
            tools: [Self.baseTool],
            output: .jsonSchema(schema)
        )
        #expect(prepared.messages == Self.baseMessages)
        #expect(prepared.tools?.count == 1)
        #expect(prepared.syntheticToolName == nil)
        #expect(prepared.promptAugmentation == nil)
        guard case let .jsonSchema(responseSchema)? = prepared.responseFormat else {
            Issue.record("Expected JSON schema response format")
            return
        }
        #expect(responseSchema.name == schema.name)
    }

    @Test("Ollama adapter augments the prompt and still emits a JSON schema response format")
    func ollamaAdapter() {
        let adapter = PromptAugmentedJSONSchemaAdapter()
        let schema = Self.tagSchema()

        let prepared = adapter.prepareRequest(
            messages: Self.baseMessages,
            tools: [Self.baseTool],
            output: .jsonSchema(schema)
        )
        #expect(prepared.messages.last?.content.contains("Schema name: \(schema.name)") == true)
        #expect(prepared.promptAugmentation?.contains("JSON Schema") == true)
        #expect(prepared.tools?.count == 1)
        #expect(prepared.syntheticToolName == nil)
        guard case let .jsonSchema(responseSchema)? = prepared.responseFormat else {
            Issue.record("Expected JSON schema response format")
            return
        }
        #expect(responseSchema.name == schema.name)
    }

    @Test("Anthropic adapter uses a forced synthetic tool")
    func anthropicAdapter() {
        let adapter = DefaultStructuredOutputAdapter()
        let schema = Self.tagSchema()

        let prepared = adapter.prepareRequest(
            messages: Self.baseMessages,
            tools: [Self.baseTool],
            output: .jsonSchema(schema)
        )
        #expect(prepared.messages == Self.baseMessages)
        #expect(prepared.responseFormat == nil)
        #expect(prepared.promptAugmentation == nil)
        #expect(prepared.toolChoice == .function("emit_structured_response"))
        #expect(prepared.syntheticToolName == "emit_structured_response")
        #expect(prepared.tools?.count == 2)
        #expect(prepared.tools?.contains(where: { $0.name == Self.baseTool.name }) == true)
        #expect(prepared.tools?.contains(where: { $0.name == "emit_structured_response" }) == true)
    }

    @Test("OpenAI-compatible adapter uses native JSON schema response format with prompt augmentation")
    func openAICompatibleAdapter() {
        let adapter = PromptAugmentedJSONSchemaAdapter()
        let schema = Self.tagSchema()

        let prepared = adapter.prepareRequest(
            messages: Self.baseMessages,
            tools: [Self.baseTool],
            output: .jsonSchema(schema)
        )
        #expect(prepared.messages.last?.content.contains("Schema name: \(schema.name)") == true)
        #expect(prepared.promptAugmentation?.contains("JSON Schema") == true)
        #expect(prepared.tools?.count == 1)
        #expect(prepared.syntheticToolName == nil)
        #expect(prepared.toolChoice == nil)
        guard case let .jsonSchema(responseSchema)? = prepared.responseFormat else {
            Issue.record("Expected JSON schema response format")
            return
        }
        #expect(responseSchema.name == schema.name)
        #expect(responseSchema.description == schema.description)
        #expect(responseSchema.strict == schema.strict)
    }

    @Test("Default adapter uses synthetic tool fallback for JSON schema")
    func defaultAdapter() {
        let adapter = DefaultStructuredOutputAdapter()

        let jsonObjectPrepared = adapter.prepareRequest(
            messages: Self.baseMessages,
            tools: [Self.baseTool],
            output: .jsonObject
        )
        #expect(jsonObjectPrepared.responseFormat == .jsonObject)

        let schema = Self.tagSchema()
        let jsonSchemaPrepared = adapter.prepareRequest(
            messages: Self.baseMessages,
            tools: [Self.baseTool],
            output: .jsonSchema(schema)
        )
        #expect(jsonSchemaPrepared.toolChoice == .function("emit_structured_response"))
        #expect(jsonSchemaPrepared.syntheticToolName == "emit_structured_response")
        #expect(jsonSchemaPrepared.responseFormat == nil)
    }

}
