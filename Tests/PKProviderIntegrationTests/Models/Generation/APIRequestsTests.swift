import Foundation
import PKContracts
import PKUtilities
import Testing

@Suite(.tags(.unit)) final class APIRequestsTests {
    @Test
    func testChatCompletionsRequestEncodesDeterministically() throws {
        let query = ChatCompletionsChatRequest(
            messages: [.init(role: "user", content: .text("Hello"))],
            model: "test-model",
            stream: false
        )
        let encoder = ChatCompletionsWire.sortedEncoder()
        let first = try encoder.encode(query)
        let second = try encoder.encode(query)
        #expect(first == second)
        let decoded = try JSONDecoder().decode(ChatCompletionsChatRequest.self, from: first)
        #expect(decoded.model == "test-model")
        #expect(decoded.messages.first?.role == "user")
    }

    @Test
    func testChatCompletionsRequestWithToolsEncodes() throws {
        let tool = ChatCompletionsTool(function: .init(
            name: "get_weather",
            description: "Gets the weather",
            parameters: nil,
            strict: nil
        ))
        let query = ChatCompletionsChatRequest(
            messages: [.init(role: "user", content: .text("What's the weather?"))],
            model: "test-model",
            toolChoice: .auto,
            tools: [tool],
            stream: false
        )
        let data = try ChatCompletionsWire.sortedEncoder().encode(query)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("get_weather"))
    }
}
