import Foundation
import PKContracts
import PKOpenAIProvider
import Testing

enum ConsumerFailure: Error, Equatable {
    case providerFailure
}

struct ConsumerRequest: Sendable {
    let messages: [LLMMessage]
    let tools: [LLMToolDefinition]?
    let toolChoice: LLMToolChoice?
    let responseFormat: LLMResponseFormat?
}

actor ScriptedProvider: LLMClientProtocol {
    enum Step: Sendable {
        case chunks([LLMStreamChunk])
        case chunksThenFailure([LLMStreamChunk], ConsumerFailure)
        case failure(ConsumerFailure)
        case hang(initial: LLMStreamChunk?)
    }

    private var steps: [Step]
    private var stepIndex = 0
    private var recorded: [ConsumerRequest] = []
    private(set) var didObserveCancellation = false
    private(set) var didYieldInitial = false

    nonisolated var promptCachingCapability: PromptCachingCapability { .none }

    init(steps: [Step]) {
        self.steps = steps
    }

    var requests: [ConsumerRequest] {
        recorded
    }

    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters _: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        recorded.append(ConsumerRequest(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat
        ))
        let step = steps.isEmpty ? .chunks([]) : steps[min(stepIndex, steps.count - 1)]
        stepIndex += 1
        return makeStream(for: step)
    }

    private func makeStream(for step: Step) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            switch step {
            case let .chunks(chunks):
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            case let .chunksThenFailure(chunks, error):
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish(throwing: error)
            case let .failure(error):
                continuation.finish(throwing: error)
            case let .hang(initial):
                let task = Task { [weak self] in
                    if let initial {
                        continuation.yield(initial)
                        await self?.recordInitialYield()
                    }
                    do {
                        try await Task.sleep(for: .seconds(60))
                        continuation.finish()
                    } catch {
                        await self?.recordCancellation()
                        continuation.finish(throwing: CancellationError())
                    }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }

    private func recordInitialYield() {
        didYieldInitial = true
    }

    private func recordCancellation() {
        didObserveCancellation = true
    }
}

private func terminal(
    content: String? = nil,
    toolCalls: [LLMToolCallDelta]? = nil,
    finishReason: String? = "stop",
    usage: LLMTokenUsage? = nil
) -> LLMStreamChunk {
    LLMStreamChunk(
        id: "response-1",
        model: "generic-model",
        choices: [LLMStreamChoice(
            index: 0,
            delta: LLMStreamDelta(content: content, toolCalls: toolCalls),
            finishReason: finishReason
        )],
        usage: usage
    )
}

private func collect(_ stream: AsyncThrowingStream<LLMStreamChunk, Error>) async throws -> [LLMStreamChunk] {
    var chunks: [LLMStreamChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

@Suite("Generic model consumer")
struct GenericModelConsumerTests {
    @Test("a host completes a tool round through the generic provider contract")
    func hostToolRound() async throws {
        let provider = ScriptedProvider(steps: [
            .chunks([terminal(
                toolCalls: [LLMToolCallDelta(
                    index: 0,
                    id: "call_weather",
                    function: LLMToolCallDeltaFunction(
                        name: "get_weather",
                        arguments: #"{"city":"Paris"}"#
                    )
                )],
                finishReason: "tool_calls"
            )]),
            .chunks([terminal(content: "Sunny, 21 C.")]),
        ])
        let client: any LLMClientProtocol = provider
        let tools = [LLMToolDefinition(name: "get_weather", description: "Current weather")]
        let user = LLMMessage(role: .user, content: "Weather in Paris?")

        let firstChunks = try await collect(client.chatStream(
            messages: [user],
            tools: tools,
            toolChoice: .auto,
            responseFormat: nil,
            generationParameters: nil
        ))
        let first = try #require(LLMStreamChunk.folding(firstChunks))
        let calls = try #require(first.choices.first?.delta.toolCalls)
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_weather")
        #expect(calls[0].function?.name == "get_weather")
        #expect(calls[0].function?.arguments == #"{"city":"Paris"}"#)

        let hostCalls = calls.map {
            LLMToolCall(
                id: $0.id ?? "",
                name: $0.function?.name ?? "",
                arguments: $0.function?.arguments ?? ""
            )
        }
        let assistant = LLMMessage(role: .assistant, content: "", toolCalls: hostCalls)
        let result = LLMMessage(role: .tool, content: "Sunny, 21 C.", toolCallID: "call_weather")
        let secondChunks = try await collect(client.chatStream(
            messages: [user, assistant, result],
            tools: tools,
            toolChoice: .auto,
            responseFormat: nil,
            generationParameters: nil
        ))
        let second = try #require(LLMStreamChunk.folding(secondChunks))

        #expect(second.choices.first?.delta.content == "Sunny, 21 C.")
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests[1].messages == [user, assistant, result])
        #expect(requests[1].messages[1].toolCalls == hostCalls)
        #expect(requests[1].messages[2].toolCallID == "call_weather")
    }

    @Test("monotonic usage and an incomplete terminal survive request-response folding")
    func usageAndIncompleteTerminal() async throws {
        let usage = LLMTokenUsage(promptTokens: 12, completionTokens: 1, totalTokens: 13)
        let provider = ScriptedProvider(steps: [
            .chunks([terminal(content: "partial", finishReason: "length", usage: usage)]),
        ])
        let client: any LLMClientProtocol = provider

        let chunk = try await client.chatCompletion(
            messages: [LLMMessage(role: .user, content: "Write a long answer")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        #expect(chunk.choices.first?.delta.content == "partial")
        #expect(chunk.choices.first?.finishReason == "length")
        #expect(chunk.usage == usage)
    }

    @Test("a partial failure preserves earlier chunks and surfaces the provider error")
    func partialFailure() async throws {
        let provider = ScriptedProvider(steps: [
            .chunksThenFailure([terminal(content: "first")], .providerFailure),
        ])
        let client: any LLMClientProtocol = provider
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        var received: [LLMStreamChunk] = []
        do {
            for try await chunk in stream {
                received.append(chunk)
            }
            Issue.record("Expected the provider failure to surface")
        } catch let error as ConsumerFailure {
            #expect(error == .providerFailure)
        }
        #expect(received.map { $0.choices.first?.delta.content } == ["first"])
    }

    @Test("cancelling the consuming task cancels the provider stream")
    func cancellation() async throws {
        let provider = ScriptedProvider(steps: [
            .hang(initial: terminal(content: "waiting")),
        ])
        let client: any LLMClientProtocol = provider

        let task = Task {
            var received: [LLMStreamChunk] = []
            let stream = await client.chatStream(
                messages: [LLMMessage(role: .user, content: "hang")],
                tools: nil,
                toolChoice: nil,
                responseFormat: nil,
                generationParameters: nil
            )
            for try await chunk in stream {
                received.append(chunk)
                if Task.isCancelled {
                    break
                }
            }
            return received
        }
        for _ in 0..<100 {
            if await provider.didYieldInitial { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await provider.didYieldInitial else {
            task.cancel()
            Issue.record("Provider did not yield the initial chunk")
            return
        }
        task.cancel()
        let received = try await task.value
        #expect(received.map { $0.choices.first?.delta.content } == ["waiting"])
        for _ in 0..<100 {
            if await provider.didObserveCancellation { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Expected cancellation to cancel the provider stream")
    }

    @Test("the OpenAI provider product conforms without any runtime dependency")
    func providerProductConformance() {
        let client: any LLMClientProtocol = OpenAIClient(apiKey: "test-key", modelName: "gpt-4.1")
        #expect(client.promptCachingCapability == .automatic)
    }
}
