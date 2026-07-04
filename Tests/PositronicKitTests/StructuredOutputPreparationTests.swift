import Foundation
import PKTestSupport
import Testing
@testable import PKShared
@testable import PositronicKit

@Suite("Structured Output Preparation Tests")
@MainActor
struct StructuredOutputPreparationTests {
    @Test("Unified preparation matches provider behavior across output modes")
    func unifiedPreparationMatchesProviderBehavior() throws {
        let baseMessages = [LLMMessage(role: .user, content: "Extract tags")]
        let baseTool = LLMToolDefinition(name: "existing_tool", description: "existing")
        let schema = StructuredOutputFixtures.tagSchemaDefinition()

        for provider in [LLMProvider.openAI, .openRouter, .ollama, .openAICompatible] {
            for output in [StructuredOutputRequest.jsonObject, .jsonSchema(schema)] {
                let prepared = StructuredOutputExecution.prepareRequest(
                    messages: baseMessages,
                    tools: [baseTool],
                    provider: provider,
                    output: output
                )

                #expect(prepared.messages.count == 1)
                #expect(prepared.tools?.first?.name == baseTool.name)

                switch (provider, output) {
                case (_, .jsonObject):
                    #expect(prepared.messages.first == baseMessages.first)
                    #expect(prepared.responseFormat == .jsonObject)
                    #expect(prepared.promptAugmentation == nil)
                    #expect(prepared.toolChoice == nil)
                    #expect(prepared.syntheticToolName == nil)
                    #expect(prepared.tools?.count == 1)
                    #expect(prepared.tools?.first?.name == baseTool.name)
                    #expect(prepared.tools?.first?.description == baseTool.description)
                case let (.openAI, .jsonSchema(schema)),
                    let (.openRouter, .jsonSchema(schema)):
                    #expect(prepared.messages.first == baseMessages.first)
                    guard case let .jsonSchema(responseSchema)? = prepared.responseFormat else {
                        Issue.record("Expected native schema response format for \(provider)")
                        continue
                    }
                    #expect(responseSchema.name == schema.name)
                    #expect(responseSchema.description == schema.description)
                    #expect(responseSchema.strict == schema.strict)
                    #expect(responseSchema.schema != nil)
                    #expect(prepared.promptAugmentation == nil)
                    #expect(prepared.toolChoice == nil)
                    #expect(prepared.syntheticToolName == nil)
                    #expect(prepared.tools?.count == 1)
                    #expect(prepared.tools?.first?.name == baseTool.name)
                    #expect(prepared.tools?.first?.description == baseTool.description)
                case let (.ollama, .jsonSchema(schema)):
                    guard case let .jsonSchema(responseSchema)? = prepared.responseFormat else {
                        Issue.record("Expected Ollama schema response format")
                        continue
                    }
                    #expect(responseSchema.name == schema.name)
                    #expect(responseSchema.description == schema.description)
                    #expect(responseSchema.strict == schema.strict)
                    #expect(responseSchema.schema != nil)
                    #expect(prepared.promptAugmentation?.contains("Schema name: \(schema.name)") == true)
                    #expect(prepared.promptAugmentation?.contains("JSON Schema") == true)
                    #expect(prepared.messages.last?.content.contains("Schema name: \(schema.name)") == true)
                    #expect(prepared.toolChoice == nil)
                    #expect(prepared.syntheticToolName == nil)
                    #expect(prepared.tools?.count == 1)
                    #expect(prepared.tools?.first?.name == baseTool.name)
                    #expect(prepared.tools?.first?.description == baseTool.description)
                case let (.openAICompatible, .jsonSchema(schema)):
                    #expect(prepared.messages.first == baseMessages.first)
                    #expect(prepared.responseFormat == nil)
                    #expect(prepared.promptAugmentation == nil)
                    #expect(prepared.toolChoice == LLMToolChoice.function("emit_structured_response"))
                    #expect(prepared.syntheticToolName == "emit_structured_response")
                    #expect(prepared.messages == baseMessages)
                    #expect(prepared.tools?.contains(where: { $0.name == "emit_structured_response" }) == true)
                    #expect(prepared.tools?.contains(where: { $0.name == baseTool.name }) == true)
                    #expect(prepared.tools?.count == 2)
                    #expect(prepared.tools?.last?.name == "emit_structured_response")
                    if let tool = prepared.tools?.last {
                        #expect(tool.description?.contains(schema.name) == true)
                        #expect(tool.parameters != nil)
                        #expect(tool.strict == schema.strict)
                    }
                }
            }
        }
    }
}
