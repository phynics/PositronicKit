import Dependencies
import Foundation
import PositronicKit
import PKShared
import OpenAI

public final class MockLLMClient: LLMClientProtocol, @unchecked Sendable {
    public var nextResponse: String = ""
    public var nextResponses: [String] = []
    public var lastMessages: [ChatQuery.ChatCompletionMessageParam] = []
    public var lastTools: [ChatQuery.ChatCompletionToolParam]?
    public var lastToolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?
    public var lastResponseFormat: ChatQuery.ResponseFormat?
    public var lastParameters: GenerationParameters?
    public var shouldThrowError: Bool = false

    /// Typed tool calls for stream simulation.
    public var nextToolCalls: [[MockToolCall]] = []

    /// Support for multi-chunk streaming. If not empty, this takes precedence over nextResponse.
    public var nextChunks: [[String]] = []

    /// Optional delay between chunks for testing cancellation.
    /// Uses `ContinuousClock` dependency — inject `ImmediateClock` in tests for instant execution.
    public var nextStreamWait: TimeInterval?

    public init() {}

    public func chatStream(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]?,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?,
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<ChatStreamResult, Error> {
        lastMessages = messages
        lastTools = tools
        lastToolChoice = toolChoice
        lastResponseFormat = responseFormat
        lastParameters = generationParameters

        if shouldThrowError {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(domain: "MockError", code: 1, userInfo: nil))
            }
        }

        let responses = nextChunks.isEmpty
            ? [nextResponses.isEmpty ? nextResponse : nextResponses.removeFirst()]
            : nextChunks.removeFirst()
        let toolCalls = nextToolCalls.isEmpty ? nil : nextToolCalls.removeFirst()
        let wait = nextStreamWait

        @Dependency(\.continuousClock) var clock

        struct StreamContext: @unchecked Sendable {
            let responses: [String]
            let toolCalls: [MockToolCall]?
            let wait: TimeInterval?
            let clock: any Clock<Duration>
        }
        let ctx = StreamContext(responses: responses, toolCalls: toolCalls, wait: wait, clock: clock)

        return AsyncThrowingStream { continuation in
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
                    let result: ChatStreamResult
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
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?
    ) async throws -> String {
        if shouldThrowError {
            throw NSError(
                domain: "MockError", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Simulated failure"]
            )
        }
        lastMessages = [.user(.init(content: .string(content)))]
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
    public var mockClient = MockLLMClient()

    /// Allows tests to provide a custom stream for chatStream calls.
    public var stubbedStream: AsyncThrowingStream<ChatStreamResult, Error>?

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
        responseFormat _: ChatQuery.ResponseFormat?,
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
            responseFormat: request.responseFormat,
            generationParameters: request.generationParameters,
            useUtilityModel: false,
            useFastModel: request.useFastModel
        )
        return LLMStreamResult(stream: stream, rawPrompt: "mock prompt")
    }

    public func chatStream(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]?,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?,
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel _: Bool,
        useFastModel _: Bool
    ) async -> AsyncThrowingStream<ChatStreamResult, Error> {
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
        return nextTags
    }

    public func generateTitle(for _: [Message]) async throws -> String {
        return "Mock Title"
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
