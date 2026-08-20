import Foundation
import OpenAI
@testable import PKOllamaProvider
@testable import PKOpenRouterProvider
import PKPrompt
import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

struct STAB8ReasoningEchoTests {
    // MARK: - LLMMessage field + history reconstruction

    @Test("LLMMessage.reasoning is optional and defaults to nil (byte-identical regression)")
    func reasoningDefaultsNil() throws {
        let message = LLMMessage(role: .assistant, content: "hi")
        #expect(message.reasoning == nil)

        let data = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["reasoning"] == nil, "nil reasoning must be omitted, not encoded as null")
    }

    @Test("LLMMessage with reasoning round-trips through Codable")
    func reasoningRoundTrips() throws {
        let message = LLMMessage(role: .assistant, content: "answer", reasoning: "because")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)
        #expect(decoded.reasoning == "because")
    }

    @Test("History reconstruction sets LLMMessage.reasoning from persisted Message.reasoning")
    func historyReconstructionThreadsThink() async throws {
        let history = [
            Message(content: "answer", role: .assistant, reasoning: "step-by-step reasoning"),
        ]

        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "next",
                contextNotes: [],
                memories: [],
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
        )
        let messages = prompt.buildMessages()

        guard let assistant = messages.first(where: { $0.role == .assistant }) else {
            Issue.record("expected an assistant history message")
            return
        }
        #expect(assistant.reasoning == "step-by-step reasoning")
    }

    @Test("Message with nil think produces LLMMessage with nil reasoning (byte-identical regression)")
    func nilThinkProducesNilReasoning() async throws {
        let history = [Message(content: "answer", role: .assistant)] // think defaults to nil

        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "next",
                contextNotes: [],
                memories: [],
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
        )
        let messages = prompt.buildMessages()
        let assistant = try #require(messages.first(where: { $0.role == .assistant }))
        #expect(assistant.reasoning == nil)
        let data = try JSONEncoder().encode(assistant)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["reasoning"] == nil, "nil reasoning must be omitted from encoded message")
    }

    // MARK: - Ollama outbound

    @Test("Ollama outbound message includes thinking when LLMMessage.reasoning is present")
    func ollamaOutboundIncludesThinking() throws {
        let message = LLMMessage(role: .assistant, content: "answer", reasoning: "the reasoning")
        let ollama = OllamaMessage(from: message)
        #expect(ollama.thinking == "the reasoning")

        let data = try JSONEncoder().encode(ollama)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["thinking"] as? String == "the reasoning")
    }

    @Test("Ollama outbound message omits thinking when reasoning is nil (byte-identical regression)")
    func ollamaOutboundOmitsThinkingWhenNil() throws {
        let message = LLMMessage(role: .assistant, content: "answer")
        let ollama = OllamaMessage(from: message)
        #expect(ollama.thinking == nil)

        let data = try JSONEncoder().encode(ollama)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["thinking"] == nil, "nil thinking must be omitted")
        #expect(Set(object.keys) == ["role", "content"], "only role/content should remain")
    }

    // MARK: - OpenRouter outbound

    @Test("OpenRouter outbound message includes reasoning when LLMMessage.reasoning is present")
    func openRouterOutboundIncludesReasoning() throws {
        let message = LLMMessage(role: .assistant, content: "answer", reasoning: "chain thought")
        let orMessage = OpenRouterMessage(message)
        #expect(orMessage.reasoning == "chain thought")

        let data = try JSONEncoder().encode(orMessage)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["reasoning"] as? String == "chain thought")
    }

    @Test("OpenRouter outbound message omits reasoning when nil (byte-identical regression)")
    func openRouterOutboundOmitsReasoningWhenNil() throws {
        let message = LLMMessage(role: .assistant, content: "answer", toolCallID: nil)
        let orMessage = OpenRouterMessage(message)
        #expect(orMessage.reasoning == nil)

        let data = try JSONEncoder().encode(orMessage)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["reasoning"] == nil, "nil reasoning must be omitted")
        #expect(!object.keys.contains("reasoning"))
    }

    // MARK: - OpenAI outbound (omits reasoning — chat completions has no such input field)

    @Test("OpenAI outbound omits reasoning even when LLMMessage.reasoning is present")
    func openAIOutboundOmitsReasoning() throws {
        let message = LLMMessage(role: .assistant, content: "answer", reasoning: "should be dropped")
        let param = try message.toOpenAIMessageParam()

        // Encode the openai-swift ChatCompletionMessageParam and assert no `reasoning` key.
        let encoder = JSONEncoder()
        // openai-swift uses snake_case CodingKeys (tool_calls); encode without convertFromSnakeCase.
        let data = try encoder.encode(param)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["reasoning"] == nil, "OpenAI chat completions must not carry a reasoning field")
        #expect(!object.keys.contains("reasoning"))
        #expect(object["role"] as? String == "assistant")
    }
}
