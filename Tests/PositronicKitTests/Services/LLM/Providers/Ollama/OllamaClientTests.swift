import Testing
import Foundation
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
}
