import Foundation
import Testing
@testable import PKContracts

struct LLMStreamChunkFoldingTests {
    @Test("Folding joins response deltas and retains terminal metadata")
    func foldingJoinsTextReasoningToolsAndUsage() throws {
        let chunks = [
            LLMStreamChunk(
                id: "response",
                model: "model-a",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(
                        role: .assistant,
                        content: "Hello ",
                        reasoning: "First ",
                        toolCalls: [LLMToolCallDelta(
                            index: 0,
                            id: "call-1",
                            function: LLMToolCallDeltaFunction(name: "look", arguments: "{\"city\":")
                        )]
                    )
                )]
            ),
            LLMStreamChunk(
                id: "response",
                model: "model-b",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(
                        role: .assistant,
                        content: "world",
                        reasoning: "thought",
                        toolCalls: [LLMToolCallDelta(
                            index: 0,
                            function: LLMToolCallDeltaFunction(name: "up", arguments: "\"Paris\"}")
                        )]
                    ),
                    finishReason: "tool_calls"
                )],
                usage: LLMTokenUsage(promptTokens: 2, completionTokens: 3, totalTokens: 5)
            ),
        ]

        let folded = try #require(LLMStreamChunk.folding(chunks))
        let choice = try #require(folded.choices.first)
        let toolCall = try #require(choice.delta.toolCalls?.first)
        #expect(folded.id == "response")
        #expect(folded.model == "model-b")
        #expect(choice.delta.content == "Hello world")
        #expect(choice.delta.reasoning == "First thought")
        #expect(choice.finishReason == "tool_calls")
        #expect(toolCall.id == "call-1")
        #expect(toolCall.function?.name == "lookup")
        #expect(toolCall.function?.arguments == #"{"city":"Paris"}"#)
        #expect(folded.usage == LLMTokenUsage(promptTokens: 2, completionTokens: 3, totalTokens: 5))
    }

    @Test("Folding preserves parallel choices and their independent deltas")
    func foldingPreservesParallelChoices() throws {
        let chunks = [
            LLMStreamChunk(
                id: "response",
                model: "model",
                choices: [
                    LLMStreamChoice(index: 1, delta: LLMStreamDelta(content: "second")),
                    LLMStreamChoice(index: 0, delta: LLMStreamDelta(content: "first")),
                ]
            ),
            LLMStreamChunk(
                id: "response",
                model: "model",
                choices: [
                    LLMStreamChoice(index: 0, delta: LLMStreamDelta(content: " choice"), finishReason: "stop"),
                    LLMStreamChoice(index: 1, delta: LLMStreamDelta(content: " choice"), finishReason: "length"),
                ]
            ),
        ]

        let folded = try #require(LLMStreamChunk.folding(chunks))
        #expect(folded.choices.map(\.index) == [1, 0])
        #expect(folded.choices[0].delta.content == "second choice")
        #expect(folded.choices[0].finishReason == "length")
        #expect(folded.choices[1].delta.content == "first choice")
        #expect(folded.choices[1].finishReason == "stop")
    }

    @Test("Folding returns nil for an empty stream")
    func foldingEmptyChunksReturnsNil() {
        #expect(LLMStreamChunk.folding([]) == nil)
    }

    @Test("Default chat completion folds the client's stream")
    func defaultChatCompletionFoldsStream() async throws {
        let chunks = [
            LLMStreamChunk(id: "id", model: "model", choices: [.init(index: 2, delta: .init(content: "hello "))]),
            LLMStreamChunk(id: "id", model: "model", choices: [.init(index: 2, delta: .init(content: "world"), finishReason: "stop")]),
        ]
        let concrete = FoldingStreamClient(chunks: chunks)
        let client: any LLMClientProtocol = concrete

        let response = try await client.chatCompletion(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            responseModalities: [.text, .audio],
            audioOutput: .init(format: .wav, voice: "alloy")
        )

        #expect(response == LLMStreamChunk.folding(chunks))
        #expect(await concrete.lastModalities == [.text, .audio])
        #expect(await concrete.lastAudioOutput == .init(format: .wav, voice: "alloy"))
    }

    @Test("Folding keeps the last nonempty identity and last nonnil metadata")
    func foldingMetadataAndEmptyValues() throws {
        let firstUsage = LLMTokenUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2)
        let lastUsage = LLMTokenUsage(promptTokens: 2, completionTokens: 3, totalTokens: 5)
        let chunks = [
            LLMStreamChunk(id: "first", model: "first-model", choices: [.init(index: 0, delta: .init(content: "", reasoning: ""), finishReason: "length")], usage: firstUsage),
            LLMStreamChunk(id: "last", model: "", choices: [.init(index: 0, delta: .init(), finishReason: "stop")], usage: lastUsage),
            LLMStreamChunk(id: "", model: "last-model", choices: [.init(index: 0, delta: .init())]),
            LLMStreamChunk(id: "", model: "", choices: []),
        ]
        let folded = try #require(LLMStreamChunk.folding(chunks))
        #expect(folded.id == "last")
        #expect(folded.model == "last-model")
        #expect(folded.usage == lastUsage)
        #expect(folded.choices.first?.finishReason == "stop")
        #expect(folded.choices.first?.delta == .init(role: .assistant))
        let empty = try #require(LLMStreamChunk.folding([.init(id: "", model: "", choices: [])]))
        #expect(empty.choices == [.init(index: 0, delta: .init(role: .assistant))])
    }

    @Test("Folding joins audio bytes and transcripts with the last format and continuation")
    func foldingAudio() throws {
        let firstReference = AudioContinuationReference(provider: .openAI, id: "first", expiresAt: Date(timeIntervalSince1970: 100))
        let lastReference = AudioContinuationReference(provider: .openAI, id: "last", expiresAt: Date(timeIntervalSince1970: 200))
        let chunks = [
            LLMStreamChunk(id: "id", model: "model", choices: [.init(index: 0, delta: .init(audio: .init(data: Data([1, 2]), format: .wav, transcript: "hello ", continuation: firstReference)))]),
            LLMStreamChunk(id: "id", model: "model", choices: [.init(index: 0, delta: .init(audio: .init(data: Data([3]), format: .mp3, transcript: "world", continuation: lastReference)))]),
            LLMStreamChunk(id: "id", model: "model", choices: [.init(index: 0, delta: .init())]),
        ]
        let folded = try #require(LLMStreamChunk.folding(chunks))
        #expect(folded.choices.first?.delta.audio == .init(data: Data([1, 2, 3]), format: .mp3, transcript: "hello world", continuation: lastReference))
        let noTranscript = try #require(LLMStreamChunk.folding([
            .init(id: "id", model: "model", choices: [.init(index: 0, delta: .init(audio: .init(data: Data(), format: .wav, transcript: "")))]),
        ]))
        #expect(noTranscript.choices.first?.delta.audio?.transcript == nil)
        #expect(noTranscript.choices.first?.delta.audio?.continuation == nil)
        let clearedReference = try #require(LLMStreamChunk.folding([
            chunks[0],
            .init(id: "id", model: "model", choices: [.init(index: 0, delta: .init(audio: .init(data: Data(), format: .mp3)))]),
        ]))
        #expect(clearedReference.choices.first?.delta.audio?.format == .mp3)
        #expect(clearedReference.choices.first?.delta.audio?.continuation == nil)
        #expect(clearedReference.choices.first?.delta.audio?.transcript == "hello ")
    }

    @Test("Folding groups interleaved tool indices per choice and keeps the first ID")
    func foldingInterleavedTools() throws {
        let chunks = [
            LLMStreamChunk(id: "id", model: "model", choices: [
                .init(index: 1, delta: .init(toolCalls: [
                    .init(index: 4, function: .init(name: "look", arguments: "{")),
                    .init(index: 2, id: "second", function: .init(name: "time", arguments: "[")),
                ])),
                .init(index: 0, delta: .init(toolCalls: [.init(index: 4, id: "other-choice", function: .init(name: "independent", arguments: "{}"))])),
            ]),
            LLMStreamChunk(id: "id", model: "model", choices: [.init(index: 1, delta: .init(toolCalls: [
                .init(index: 2, id: "ignored", function: .init(arguments: "]")),
                .init(index: 4, id: "first", function: .init(name: "up", arguments: "}")),
            ]))]),
            LLMStreamChunk(id: "id", model: "model", choices: [.init(index: 1, delta: .init(toolCalls: [.init(index: 4, id: "ignored")]))]),
        ]
        let folded = try #require(LLMStreamChunk.folding(chunks))
        #expect(folded.choices[0].delta.toolCalls == [
            .init(index: 4, id: "first", function: .init(name: "lookup", arguments: "{}")),
            .init(index: 2, id: "second", function: .init(name: "time", arguments: "[]")),
        ])
        #expect(folded.choices[1].delta.toolCalls == [.init(index: 4, id: "other-choice", function: .init(name: "independent", arguments: "{}"))])
    }

    @Test("Folding retains empty first tool IDs and normalizes absent tool fragments")
    func foldingEmptyToolFragments() throws {
        let folded = try #require(LLMStreamChunk.folding([
            .init(id: "id", model: "model", choices: [.init(index: 0, delta: .init(toolCalls: [.init(index: 0, id: "", function: .init(name: "", arguments: ""))]))]),
            .init(id: "", model: "", choices: [.init(index: 0, delta: .init(toolCalls: [.init(index: 0, id: "ignored")]))]),
        ]))
        #expect(folded.choices.first?.delta.toolCalls == [.init(index: 0, id: "", function: .init())])
    }

    @Test("Default completion reports the typed empty-response error")
    func defaultCompletionEmptyStream() async throws {
        let client: any LLMClientProtocol = FoldingStreamClient(chunks: [])
        await #expect(throws: LLMServiceError.emptyResponse(provider: "LLM")) {
            _ = try await client.chatCompletion(messages: [], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil)
        }
    }

    @Test("Default sendMessage dispatches to the native completion requirement")
    func defaultSendMessageUsesCompletion() async throws {
        let client: any LLMClientProtocol = NativeCompletionClient()
        #expect(try await client.sendMessage("hello") == "native")
    }
}

private actor FoldingStreamClient: LLMClientProtocol {
    let chunks: [LLMStreamChunk]
    private(set) var lastModalities: Set<ResponseModality>?
    private(set) var lastAudioOutput: AudioOutputOptions?

    init(chunks: [LLMStreamChunk]) { self.chunks = chunks }

    func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: [.text], audioOutput: nil)
    }

    func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lastModalities = responseModalities
        lastAudioOutput = audioOutput
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private struct NativeCompletionClient: LLMClientProtocol {
    func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMServiceError.invalidConfiguration) }
    }

    func chatCompletion(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?) async throws -> LLMStreamChunk {
        LLMStreamChunk(id: "native", model: "model", choices: [.init(index: 0, delta: .init(content: "native"), finishReason: "stop")])
    }
}
