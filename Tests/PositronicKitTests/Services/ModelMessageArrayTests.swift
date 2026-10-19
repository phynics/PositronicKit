import Foundation
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

@Suite("Kit model message arrays", .tags(.integration))
struct ModelMessageArrayTests {
    private static let tool = LLMToolDefinition(
        name: "get_weather",
        description: "Looks up the current weather."
    )

    private func makeRuntime(
        llm: MockLLMService,
        generationParameters: GenerationParameters? = nil
    ) -> TestRuntime {
        TestRuntime(
            workspaceRoot: TestRuntime.uniqueWorkspaceRoot(),
            llm: llm,
            generationParameters: generationParameters
        )
    }

    @Test("generate(messages:) forwards host messages, tools, choice, and schema")
    func generateForwardsHostRequest() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["weather is sunny"]]
        let runtime = makeRuntime(llm: llm)
        let messages = [
            LLMMessage(role: .system, content: "Use the weather tool."),
            LLMMessage(role: .user, content: "Weather in Paris?"),
        ]
        let schema = LLMResponseSchema(name: "WeatherAnswer")

        let response = try await runtime.runtime.model.generate(
            messages: messages,
            tools: [Self.tool],
            toolChoice: .function("get_weather"),
            responseFormat: .jsonSchema(schema)
        )

        #expect(response.content == "weather is sunny")
        let capture = try #require(llm.generationCaptureHistory.last)
        #expect(capture.messages == messages)
        #expect(capture.tools?.map(\.name) == ["get_weather"])
        #expect(capture.toolChoice == .function("get_weather"))
        #expect(capture.responseFormat == .jsonSchema(schema))
        #expect(capture.modelTier == .primary)
    }

    @Test("generate(messages:) returns complete tool calls in provider order")
    func generateReturnsCompleteToolCalls() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextRawStreamChunks = [[
            LLMStreamChunk(
                id: "response-1",
                model: "test-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(toolCalls: [
                        LLMToolCallDelta(
                            index: 0,
                            id: "call_weather",
                            function: LLMToolCallDeltaFunction(name: "get_weather", arguments: "{\"city\":")
                        ),
                        LLMToolCallDelta(
                            index: 1,
                            id: "call_time",
                            function: LLMToolCallDeltaFunction(name: "get_time", arguments: "{\"zone\":")
                        ),
                    ])
                )]
            ),
            LLMStreamChunk(
                id: "response-1",
                model: "test-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(toolCalls: [
                        LLMToolCallDelta(
                            index: 0,
                            function: LLMToolCallDeltaFunction(arguments: "\"Paris\"}")
                        ),
                        LLMToolCallDelta(
                            index: 1,
                            function: LLMToolCallDeltaFunction(arguments: "\"Europe/London\"}")
                        ),
                    ]),
                    finishReason: "tool_calls"
                )]
            ),
        ]]
        let runtime = makeRuntime(llm: llm)

        let response = try await runtime.runtime.model.generate(
            messages: [LLMMessage(role: .user, content: "Check both.")]
        )

        #expect(response.toolCalls == [
            LLMToolCall(id: "call_weather", name: "get_weather", arguments: #"{"city":"Paris"}"#),
            LLMToolCall(id: "call_time", name: "get_time", arguments: #"{"zone":"Europe/London"}"#),
        ])
        #expect(response.finishReason == "tool_calls")
    }

    @Test("stream(messages:) preserves chunk order and host request fields")
    func streamMessagesPreservesChunks() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextRawStreamChunks = [[
            LLMStreamChunk(
                id: "response-2",
                model: "test-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: "first")
                )]
            ),
            LLMStreamChunk(
                id: "response-2",
                model: "test-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(
                        content: " second",
                        toolCalls: [LLMToolCallDelta(
                            index: 0,
                            id: "call_1",
                            function: LLMToolCallDeltaFunction(name: "lookup", arguments: "{}")
                        )]
                    ),
                    finishReason: "tool_calls"
                )]
            ),
        ]]
        let runtime = makeRuntime(llm: llm)
        let messages = [LLMMessage(role: .user, content: "Look it up.")]

        let chunks = try await runtime.runtime.model.stream(
            messages: messages,
            tools: [Self.tool],
            toolChoice: .auto,
            responseFormat: .jsonObject
        ).collect()

        #expect(chunks.map { $0.choices.first?.delta.content } == ["first", " second"])
        #expect(chunks.last?.choices.first?.delta.toolCalls?.first?.id == "call_1")
        let capture = try #require(llm.generationCaptureHistory.last)
        #expect(capture.messages == messages)
        #expect(capture.tools?.map(\.name) == ["get_weather"])
        #expect(capture.toolChoice == .auto)
        #expect(capture.responseFormat == .jsonObject)
    }

    @Test("message-array calls use the runtime's configured generation parameters")
    func messageArrayUsesConfiguredParameters() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["ok"]]
        let defaults = GenerationParameters(temperature: 0.3, maxTokens: 64)
        let runtime = makeRuntime(llm: llm, generationParameters: defaults)

        _ = try await runtime.runtime.model.generate(
            messages: [LLMMessage(role: .user, content: "hello")]
        )

        #expect(llm.mockClient.lastParameters == defaults)
    }

    @Test("message-array request-response delivers one terminal chunk")
    func messageArrayRequestResponse() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["one", " ", "chunk"]]
        let runtime = makeRuntime(llm: llm)

        let chunks = try await runtime.runtime.model.stream(
            messages: [LLMMessage(role: .user, content: "hello")],
            transport: .requestResponse
        ).collect()

        #expect(chunks.count == 1)
        #expect(chunks.first?.choices.first?.delta.content == "one chunk")
        #expect(llm.completionCaptureHistory.count == 1)
        #expect(llm.generationCaptureHistory.isEmpty)
    }

    @Test("generate(messages:) preserves ordered multimodal content")
    func generatePreservesMultimodalOrder() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["described"]]
        let runtime = makeRuntime(llm: llm)
        let content = MessageContent(parts: [
            .text("Before"),
            .image(ImageContent(data: Data([0x01]), mediaType: "image/png")),
            .text("After"),
        ])

        _ = try await runtime.runtime.model.generate(
            messages: [LLMMessage(role: .user, content: content)]
        )

        let capture = try #require(llm.generationCaptureHistory.last)
        #expect(capture.messages == [LLMMessage(role: .user, content: content)])
        #expect(capture.messages.first?.messageContent.parts == content.parts)
    }

    @Test("generate(messages:) surfaces an incomplete terminal finish reason and usage")
    func generateSurfacesIncompleteTerminal() async throws {
        let llm = MockLLMService()
        let usage = LLMTokenUsage(promptTokens: 4, completionTokens: 2, totalTokens: 6)
        llm.mockClient.nextRawStreamChunks = [[
            LLMStreamChunk(
                id: "response-3",
                model: "test-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: "partial"),
                    finishReason: "length"
                )],
                usage: usage
            )
        ]]
        let runtime = makeRuntime(llm: llm)

        let response = try await runtime.runtime.model.generate(
            messages: [LLMMessage(role: .user, content: "answer fully")]
        )

        #expect(response.content == "partial")
        #expect(response.finishReason == "length")
        #expect(response.usage == usage)
    }
}
