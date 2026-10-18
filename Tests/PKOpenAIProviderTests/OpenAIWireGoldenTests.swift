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
        let messageItem = try JSONSerialization.data(withJSONObject: [
            "type": "response.output_item.added",
            "output_index": 0,
            "item": ["type": "message", "id": "msg_1"],
        ])
        #expect(ResponsesEvents.chunk(forEventType: "response.output_item.added", payload: messageItem, model: "m", responseID: "r", accumulator: &acc) == nil)

        let textPayload = try JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": "hello"])
        let chunk = ResponsesEvents.chunk(forEventType: "response.output_text.delta", payload: textPayload, model: "m", responseID: "r", accumulator: &acc)
        #expect(chunk?.choices.first?.delta.content == "hello")
        #expect(chunk?.choices.first?.delta.toolCalls == nil)
        #expect(acc.hasYielded)
        let donePayload = try JSONSerialization.data(withJSONObject: ["type": "response.completed", "usage": ["input_tokens": 3, "output_tokens": 5, "total_tokens": 8]])
        let done = ResponsesEvents.chunk(forEventType: "response.completed", payload: donePayload, model: "m", responseID: "r", accumulator: &acc)
        #expect(done?.usage?.totalTokens == 8)
    }

    @Test("Responses stream folds authoritative function-call metadata with fragmented arguments")
    func responsesStreamFunctionCallIdentity() throws {
        var accumulator = ResponsesStreamAccumulator()
        var chunks: [LLMStreamChunk] = []

        func append(_ type: String, _ payload: [String: Any]) throws -> LLMStreamChunk? {
            let data = try JSONSerialization.data(withJSONObject: payload)
            return ResponsesEvents.chunk(
                forEventType: type,
                payload: data,
                model: "gpt-4o",
                responseID: "resp_1",
                accumulator: &accumulator
            )
        }

        let weatherItem = try append("response.output_item.added", [
            "type": "response.output_item.added",
            "output_index": 0,
            "item": ["id": "fc_weather", "type": "function_call", "call_id": "call_weather", "name": "get_weather", "arguments": ""],
        ])
        let timeItem = try append("response.output_item.added", [
            "type": "response.output_item.added",
            "output_index": 1,
            "item": ["id": "fc_time", "type": "function_call", "call_id": "call_time", "name": "get_time", "arguments": ""],
        ])
        if let weatherItem { chunks.append(weatherItem) }
        if let timeItem { chunks.append(timeItem) }

        for (index, itemID, delta) in [
            (0, "fc_weather", #"{"city":""#),
            (1, "fc_time", #"{"zone":""#),
            (0, "fc_weather", #"Paris"}"#),
            (1, "fc_time", #"Europe/London"}"#),
        ] {
            let chunk = try append("response.function_call_arguments.delta", [
                "type": "response.function_call_arguments.delta",
                "output_index": index,
                "item_id": itemID,
                "delta": delta,
            ])
            if let chunk {
                let streamedCall = try #require(chunk.choices.first?.delta.toolCalls?.first)
                #expect(streamedCall.id == nil)
                #expect(streamedCall.function?.name == nil)
                chunks.append(chunk)
            }
        }

        let weatherDone = try append("response.function_call_arguments.done", [
            "type": "response.function_call_arguments.done",
            "output_index": 0,
            "item_id": "fc_weather",
            "arguments": #"{"city":"Paris"}"#,
        ])
        let timeDone = try append("response.function_call_arguments.done", [
            "type": "response.function_call_arguments.done",
            "output_index": 1,
            "item_id": "fc_time",
            "arguments": #"{"zone":"Europe/London"}"#,
        ])
        #expect(weatherDone == nil)
        #expect(timeDone == nil)

        let folded = try #require(LLMStreamChunk.folding(chunks))
        let calls = try #require(folded.choices.first?.delta.toolCalls)
        #expect(calls.map(\.index) == [0, 1])
        #expect(calls.map(\.id) == ["call_weather", "call_time"])
        #expect(calls.map { $0.function?.name } == ["get_weather", "get_time"])
        #expect(calls.map { $0.function?.arguments } == [#"{"city":"Paris"}"#, #"{"zone":"Europe/London"}"#])

        let text = try append("response.output_text.delta", ["type": "response.output_text.delta", "delta": "done"])
        #expect(text?.choices.first?.delta.content == "done")
        #expect(text?.choices.first?.delta.toolCalls == nil)
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
