import Foundation
import PKShared
import PositronicKit

public final class MockLLMClient: LLMClientProtocol, @unchecked Sendable {
    /// Clock used to drive inter-chunk delays. Inject `ImmediateClock` in tests for instant
    /// execution, or leave the default `ContinuousClock` for realistic timing.
    public let clock: any Clock<Duration>
    public var nextResponse: String = ""
    public var nextResponses: [String] = []
    public var lastMessages: [LLMMessage] = []
    /// Full history of messages passed to each `chatStream` call, in call order. Useful for
    /// asserting on multi-turn tool-loop behavior where `lastMessages` only exposes the final call.
    public var messageHistory: [[LLMMessage]] = []
    public var lastTools: [LLMToolDefinition]?
    public var lastToolChoice: LLMToolChoice?
    public var lastResponseFormat: LLMResponseFormat?
    public var lastParameters: GenerationParameters?
    public var shouldThrowError: Bool = false
    public var errorToThrow: Error = NSError(
        domain: "MockError",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Simulated failure"]
    )
    public var streamCallCount: Int = 0
    public var neverFinishingStreamCallIndices: Set<Int> = []

    /// Typed tool calls for stream simulation.
    public var nextToolCalls: [[MockToolCall]] = []

    /// Support for multi-chunk streaming. If not empty, this takes precedence over nextResponse.
    public var nextChunks: [[String]] = []

    /// Raw stream chunks for cases where tests need full control over tool-call delta fragmentation.
    /// Each inner array represents one `chatStream` invocation.
    public var nextRawStreamChunks: [[LLMStreamChunk]] = []

    /// Optional delay between chunks for testing cancellation.
    /// Uses `ContinuousClock` dependency — inject `ImmediateClock` in tests for instant execution.
    public var nextStreamWait: TimeInterval?

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        streamCallCount += 1
        let streamCallIndex = streamCallCount
        lastMessages = messages
        messageHistory.append(messages)
        lastTools = tools
        lastToolChoice = toolChoice
        lastResponseFormat = responseFormat
        lastParameters = generationParameters

        if neverFinishingStreamCallIndices.contains(streamCallIndex) {
            return AsyncThrowingStream { _ in }
        }

        if shouldThrowError {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: errorToThrow)
            }
        }

        if !nextRawStreamChunks.isEmpty {
            let rawChunks = nextRawStreamChunks.removeFirst()
            let wait = nextStreamWait

            let clock = self.clock

            struct RawStreamContext: @unchecked Sendable {
                let chunks: [LLMStreamChunk]
                let wait: TimeInterval?
                let clock: any Clock<Duration>
            }
            let ctx = RawStreamContext(chunks: rawChunks, wait: wait, clock: clock)

            return AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
                let task = Task {
                    for chunk in ctx.chunks {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }

                        if let wait = ctx.wait {
                            do {
                                try await ctx.clock.sleep(for: .seconds(wait))
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                        }

                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }

                        continuation.yield(chunk)
                    }
                    continuation.finish()
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        }

        let responses = nextChunks.isEmpty
            ? [nextResponses.isEmpty ? nextResponse : nextResponses.removeFirst()]
            : nextChunks.removeFirst()
        let toolCalls = nextToolCalls.isEmpty ? nil : nextToolCalls.removeFirst()
        let wait = nextStreamWait

        let clock = self.clock

        struct StreamContext: @unchecked Sendable {
            let responses: [String]
            let toolCalls: [MockToolCall]?
            let wait: TimeInterval?
            let clock: any Clock<Duration>
        }
        let ctx = StreamContext(responses: responses, toolCalls: toolCalls, wait: wait, clock: clock)

        return AsyncThrowingStream<LLMStreamChunk, Error> { continuation in
            let task = Task {
                for (index, chunk) in ctx.responses.enumerated() {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }

                    if let wait = ctx.wait {
                        do {
                            try await ctx.clock.sleep(for: .seconds(wait))
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }

                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }

                    let isLast = index == ctx.responses.count - 1
                    let result: LLMStreamChunk
                    if let toolCalls = ctx.toolCalls, isLast {
                        result = ChatStreamResultFactory.toolCallChunk(calls: toolCalls, content: chunk)
                    } else {
                        result = ChatStreamResultFactory.textChunk(chunk, finishReason: isLast ? "stop" : nil)
                    }
                    continuation.yield(result)
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async throws -> String {
        if shouldThrowError {
            throw errorToThrow
        }
        lastMessages = [LLMMessage(role: .user, content: content)]
        lastTools = nil
        lastToolChoice = nil
        lastResponseFormat = responseFormat
        lastParameters = generationParameters
        return nextResponse
    }
}

public final class MockLLMService: LLMServiceProtocol, @unchecked Sendable, HealthCheckable {
    public var mockHealthStatus: HealthStatus = .ok
    public var mockHealthDetails: [String: String]? = ["mock": "true"]

    public func getHealthStatus() async -> HealthStatus {
        mockHealthStatus
    }

    public func getHealthDetails() async -> [String: String]? {
        mockHealthDetails
    }

    public func checkHealth() async -> HealthStatus {
        return mockHealthStatus
    }

    public var mockIsConfigured: Bool = true
    public var isConfigured: Bool {
        get async { mockIsConfigured }
    }

    public var configuration: LLMConfiguration {
        get async { mockConfig }
    }

    public var mockConfig: LLMConfiguration = .openAI
    public var nextResponse: String = ""
    public var nextTags: [String] = []
    public var nextGeneratedTitle: String = "Mock Title"
    public var generatedTitleInputs: [[Message]] = []
    public var mockClient = MockLLMClient()

    /// Allows tests to provide a custom stream for chatStream calls.
    public var stubbedStream: AsyncThrowingStream<LLMStreamChunk, Error>?

    public init() {}

    public func loadConfiguration() async {}
    public func updateConfiguration(_ config: LLMConfiguration) async throws {
        mockConfig = config
    }

    public func clearConfiguration() async {
        // can't easily change isConfigured if it's computed, but we can change mock state
    }

    public func restoreFromBackup() async throws {}
    public func exportConfiguration() async throws -> Data {
        return Data()
    }

    public func importConfiguration(from _: Data) async throws {}

    public func sendMessage(_: String) async throws -> String {
        return nextResponse
    }

    public func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String {
        return nextResponse
    }

    public func chatStreamWithContext(_ request: LLMChatRequest) async throws -> LLMStreamResult {
        let stream = await chatStream(
            messages: [],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: request.generationParameters,
            useUtilityModel: false,
            useFastModel: request.useFastModel
        )
        return LLMStreamResult(stream: stream, rawPrompt: "mock prompt")
    }

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel _: Bool,
        useFastModel _: Bool
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        if let stubbed = stubbedStream {
            return stubbed
        }
        return await mockClient.chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters
        )
    }

    public func generateTags(for _: String) async throws -> [String] {
        return nextTags.map { $0.lowercased() }
    }

    public func generateTitle(for messages: [Message]) async throws -> String {
        generatedTitleInputs.append(messages)
        let title = nextGeneratedTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        return title.isEmpty ? "New Conversation" : title
    }

    public func evaluateRecallPerformance(transcript _: String, recalledMemories _: [Memory]) async throws
        -> [String: Double]
    {
        return [:]
    }

    public func fetchAvailableModels() async throws -> [String]? {
        return ["mock-model"]
    }
}
