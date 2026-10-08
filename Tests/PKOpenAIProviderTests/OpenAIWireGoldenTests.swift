import Foundation
import Testing
@testable import PKOpenAIProvider
import PKContracts
import PKUtilities

@Suite("OpenAI wire golden JSON")
struct OpenAIWireGoldenTests {
    @Test("Chat Completions text request golden bytes are sortedKeys-deterministic")
    func chatCompletionsGolden() throws {
        let client = OpenAIClient(apiKey: "k", modelName: "gpt-4o", host: "example.com", api: .chatCompletions)
        _ = client
        let query = ChatCompletionsChatRequest(messages: [.init(role: "user", content: .text("hi"))], model: "gpt-4o", stream: false)
        let data = try ChatCompletionsWire.sortedEncoder().encode(query)
        #expect(String(data: data, encoding: .utf8) == #"{"messages":[{"content":"hi","role":"user"}],"model":"gpt-4o","stream":false}"#)
    }

    @Test("Responses text request is stateless with store false")
    func responsesGolden() throws {
        let request = ResponsesRequest(model: "gpt-4o", input: [.message(role: "user", content: [.text("hi")])], store: false, stream: false)
        let data = try ChatCompletionsWire.sortedEncoder().encode(request)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains(#""store":false"#))
        #expect(!json.contains("previous_response_id"))
    }

    @Test("Responses stream events decode")
    func responsesStreamEvents() throws {
        var acc = ResponsesStreamAccumulator()
        let textPayload = try JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": "hello"])
        let chunk = ResponsesEvents.chunk(forEventType: "response.output_text.delta", payload: textPayload, model: "m", responseID: "r", accumulator: &acc)
        #expect(chunk?.choices.first?.delta.content == "hello")
        #expect(acc.hasYielded)
        let donePayload = try JSONSerialization.data(withJSONObject: ["type": "response.completed", "usage": ["input_tokens": 3, "output_tokens": 5, "total_tokens": 8]])
        let done = ResponsesEvents.chunk(forEventType: "response.completed", payload: donePayload, model: "m", responseID: "r", accumulator: &acc)
        #expect(done?.usage?.totalTokens == 8)
    }

    @Test("API routing: automatic uses Responses for api.openai.com")
    func routing() async throws {
        let openai = OpenAIClient(apiKey: "k", host: "api.openai.com", api: .automatic)
        #expect(openai.resolvedAPI(hasAudioOutput: false) == .responses)
        #expect(openai.resolvedAPI(hasAudioOutput: true) == .chatCompletions)
        let other = OpenAIClient(apiKey: "k", host: "example.com", api: .automatic)
        #expect(other.resolvedAPI(hasAudioOutput: false) == .chatCompletions)
    }
}
