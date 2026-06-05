import Testing
import Foundation
import struct JSONSchema.Schema
import PKShared
@testable import PKOllamaProvider

@Suite struct OllamaClientTests {

    @Test func testOllamaEndpointNormalization() {
        let e1 = OllamaEndpoint(rawValue: "http://localhost:11434/")
        #expect(e1.url.absoluteString == "http://localhost:11434")
        #expect(e1.chatURL.absoluteString == "http://localhost:11434/api/chat")

        let e2 = OllamaEndpoint(rawValue: "http://localhost:11434/api")
        #expect(e2.url.absoluteString == "http://localhost:11434")

        let e3 = OllamaEndpoint(rawValue: "  http://localhost:11434/api/  ")
        #expect(e3.url.absoluteString == "http://localhost:11434")
    }

    @Test func testOllamaMessageInitialization() {
        let systemParam = LLMMessage(role: .system, content: "system prompt")
        let message = OllamaMessage(from: systemParam)
        #expect(message.role == "system")
        #expect(message.content == "system prompt")

        let userParam = LLMMessage(role: .user, content: "hello")
        let userMsg = OllamaMessage(from: userParam)
        #expect(userMsg.role == "user")
        #expect(userMsg.content == "hello")
    }

    @Test func testOllamaToolInitialization() {
        let toolParam = LLMToolDefinition(
            name: "test_tool",
            description: "test description",
            parameters: makeEmptyObjectSchema()
        )
        let tool = OllamaTool(from: toolParam)
        #expect(tool.type == "function")
        #expect(tool.function.name == "test_tool")
        #expect(tool.function.description == "test description")
    }

    @Test func testOllamaChatRequestEncodesJSONSchemaFormatAsObject() throws {
        let schema = try Schema(instance: #"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"required":["tags"]}"#)
        let request = OllamaChatRequest(
            model: "llama3.1",
            messages: [OllamaMessage(from: LLMMessage(role: .user, content: "Extract tags"))],
            stream: true,
            format: .jsonSchema(schema),
            tools: nil,
            options: nil
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let format = try #require(object["format"] as? [String: Any])

        #expect(format["type"] as? String == "object")
        #expect(format["required"] as? [String] == ["tags"])
    }

    @Test func testOllamaChatRequestEncodesJSONModeFormatAsString() throws {
        let request = OllamaChatRequest(
            model: "llama3.1",
            messages: [OllamaMessage(from: LLMMessage(role: .user, content: "Extract tags"))],
            stream: true,
            format: .jsonObject,
            tools: nil,
            options: nil
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["format"] as? String == "json")
    }
}
