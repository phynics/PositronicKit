import Foundation
import PKShared
import PKUtilities
import PositronicKit
import Synchronization

public struct MockLLMChatCapture: Sendable {
    public let messages: [LLMMessage]
    public let tools: [LLMToolDefinition]?
    public let toolChoice: LLMToolChoice?
    public let responseFormat: LLMResponseFormat?
    public let generationParameters: GenerationParameters?
    public let modelTier: ModelTier
}

public struct MockLLMSendMessageCapture: Sendable {
    public let content: String
    public let responseFormat: LLMResponseFormat?
    public let generationParameters: GenerationParameters?
    public let useUtilityModel: Bool
}

/// In-memory `LLMClientProtocol` test double.
///
/// Configurable: `nextResponse`/`nextResponses` (single/sequenced full-text replies),
/// `nextChunks` (multi-chunk streaming), `nextRawStreamChunks` (fully custom
/// `LLMStreamChunk`s, for exercising tool-call delta fragmentation), `nextToolCalls`
/// (typed tool calls appended to the last streamed chunk), `nextStreamWait` (inter-chunk
/// delay via the injectable `clock`, e.g. `ImmediateClock` for instant tests),
/// `shouldThrowError`/`errorToThrow`, and `neverFinishingStreamCallIndices` (simulate a
/// hung stream for cancellation tests).
/// Call-capture: `lastMessages`/`messageHistory` (every `chatStream` call's messages, in
/// order), `lastTools`, `lastToolChoice`, `lastResponseFormat`, `lastParameters`, and
/// `streamCallCount`.
public final class MockLLMClient: LLMClientProtocol {
    private struct State {
        var nextResponse = ""
        var nextResponses: [String] = []
        var lastMessages: [LLMMessage] = []
        var messageHistory: [[LLMMessage]] = []
        var lastTools: [LLMToolDefinition]?
        var lastToolChoice: LLMToolChoice?
        var lastResponseFormat: LLMResponseFormat?
        var lastParameters: GenerationParameters?
        var shouldThrowError = false
        var errorToThrow: any Error = NSError(
            domain: "MockError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Simulated failure"]
        )
        var streamCallCount = 0
        var neverFinishingStreamCallIndices: Set<Int> = []
        var nextToolCalls: [[MockToolCall]] = []
        var nextChunks: [[String]] = []
        var nextRawStreamChunks: [[LLMStreamChunk]] = []
        var nextStreamWait: TimeInterval?
        var lastChatCapture: MockLLMChatCapture?
        var chatCaptureHistory: [MockLLMChatCapture] = []
        var lastSendMessageCapture: MockLLMSendMessageCapture?
        var sendMessageCaptureHistory: [MockLLMSendMessageCapture] = []
    }

    private enum StreamPlan {
        case neverFinishes
        case failure(any Error)
        case raw(chunks: [LLMStreamChunk], wait: TimeInterval?)
        case content(chunks: [String], toolCalls: [MockToolCall]?, wait: TimeInterval?)
    }

    private let state = Mutex(State())

    /// Clock used to drive inter-chunk delays. Inject `ImmediateClock` in tests for instant
    /// execution, or leave the default `ContinuousClock` for realistic timing.
    public let clock: any Clock<Duration>

    public var nextResponse: String {
        get { state.withLock { $0.nextResponse } }
        set { state.withLock { $0.nextResponse = newValue } }
    }

    public var nextResponses: [String] {
        get { state.withLock { $0.nextResponses } }
        set { state.withLock { $0.nextResponses = newValue } }
    }

    public var lastMessages: [LLMMessage] {
        get { state.withLock { $0.lastMessages } }
        set { state.withLock { $0.lastMessages = newValue } }
    }

    /// Full history of messages passed to each `chatStream` call, in call order. Useful for
    /// asserting on multi-turn tool-loop behavior where `lastMessages` only exposes the final call.
    public var messageHistory: [[LLMMessage]] {
        get { state.withLock { $0.messageHistory } }
        set { state.withLock { $0.messageHistory = newValue } }
    }

    public var lastTools: [LLMToolDefinition]? {
        get { state.withLock { $0.lastTools } }
        set { state.withLock { $0.lastTools = newValue } }
    }

    public var lastToolChoice: LLMToolChoice? {
        get { state.withLock { $0.lastToolChoice } }
        set { state.withLock { $0.lastToolChoice = newValue } }
    }

    public var lastResponseFormat: LLMResponseFormat? {
        get { state.withLock { $0.lastResponseFormat } }
        set { state.withLock { $0.lastResponseFormat = newValue } }
    }

    public var lastParameters: GenerationParameters? {
        get { state.withLock { $0.lastParameters } }
        set { state.withLock { $0.lastParameters = newValue } }
    }

    public var shouldThrowError: Bool {
        get { state.withLock { $0.shouldThrowError } }
        set { state.withLock { $0.shouldThrowError = newValue } }
    }

    public var errorToThrow: Error {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    public var streamCallCount: Int {
        get { state.withLock { $0.streamCallCount } }
        set { state.withLock { $0.streamCallCount = newValue } }
    }

    public var neverFinishingStreamCallIndices: Set<Int> {
        get { state.withLock { $0.neverFinishingStreamCallIndices } }
        set { state.withLock { $0.neverFinishingStreamCallIndices = newValue } }
    }

    /// Typed tool calls for stream simulation.
    public var nextToolCalls: [[MockToolCall]] {
        get { state.withLock { $0.nextToolCalls } }
        set { state.withLock { $0.nextToolCalls = newValue } }
    }

    /// Support for multi-chunk streaming. If not empty, this takes precedence over nextResponse.
    public var nextChunks: [[String]] {
        get { state.withLock { $0.nextChunks } }
        set { state.withLock { $0.nextChunks = newValue } }
    }

    /// Raw stream chunks for cases where tests need full control over tool-call delta fragmentation.
    /// Each inner array represents one `chatStream` invocation.
    public var nextRawStreamChunks: [[LLMStreamChunk]] {
        get { state.withLock { $0.nextRawStreamChunks } }
        set { state.withLock { $0.nextRawStreamChunks = newValue } }
    }

    /// Optional delay between chunks for testing cancellation.
    /// Uses `ContinuousClock` dependency — inject `ImmediateClock` in tests for instant execution.
    public var nextStreamWait: TimeInterval? {
        get { state.withLock { $0.nextStreamWait } }
        set { state.withLock { $0.nextStreamWait = newValue } }
    }

    public var lastChatCapture: MockLLMChatCapture? {
        state.withLock { $0.lastChatCapture }
    }

    public var chatCaptureHistory: [MockLLMChatCapture] {
        state.withLock { $0.chatCaptureHistory }
    }

    public var lastSendMessageCapture: MockLLMSendMessageCapture? {
        state.withLock { $0.lastSendMessageCapture }
    }

    public var sendMessageCaptureHistory: [MockLLMSendMessageCapture] {
        state.withLock { $0.sendMessageCaptureHistory }
    }

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
        let plan = state.withLock { state -> StreamPlan in
            state.streamCallCount += 1
            let streamCallIndex = state.streamCallCount
            let capture = MockLLMChatCapture(
                messages: messages,
                tools: tools,
                toolChoice: toolChoice,
                responseFormat: responseFormat,
                generationParameters: generationParameters,
                modelTier: .primary
            )
            state.lastMessages = messages
            state.messageHistory.append(messages)
            state.lastTools = tools
            state.lastToolChoice = toolChoice
            state.lastResponseFormat = responseFormat
            state.lastParameters = generationParameters
            state.lastChatCapture = capture
            state.chatCaptureHistory.append(capture)

            if state.neverFinishingStreamCallIndices.contains(streamCallIndex) {
                return .neverFinishes
            }
            if state.shouldThrowError {
                return .failure(state.errorToThrow)
            }
            if !state.nextRawStreamChunks.isEmpty {
                return .raw(chunks: state.nextRawStreamChunks.removeFirst(), wait: state.nextStreamWait)
            }

            let responses: [String]
            if !state.nextChunks.isEmpty {
                responses = state.nextChunks.removeFirst()
            } else if !state.nextResponses.isEmpty {
                responses = [state.nextResponses.removeFirst()]
            } else {
                responses = [state.nextResponse]
            }
            let toolCalls = state.nextToolCalls.isEmpty ? nil : state.nextToolCalls.removeFirst()
            return .content(chunks: responses, toolCalls: toolCalls, wait: state.nextStreamWait)
        }

        switch plan {
        case .neverFinishes:
            return AsyncThrowingStream { _ in }
        case let .failure(error):
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        case let .raw(rawChunks, wait):
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
        case let .content(responses, toolCalls, wait):
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
    }

    public func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async throws -> String {
        let outcome: (response: String?, error: (any Error)?) = state.withLock { state in
            let capture = MockLLMSendMessageCapture(
                content: content,
                responseFormat: responseFormat,
                generationParameters: generationParameters,
                useUtilityModel: false
            )
            state.lastMessages = [LLMMessage(role: .user, content: content)]
            state.lastTools = nil
            state.lastToolChoice = nil
            state.lastResponseFormat = responseFormat
            state.lastParameters = generationParameters
            state.lastSendMessageCapture = capture
            state.sendMessageCaptureHistory.append(capture)

            if state.shouldThrowError {
                return (nil, state.errorToThrow)
            }
            let response = state.nextResponses.isEmpty
                ? state.nextResponse
                : state.nextResponses.removeFirst()
            return (response, nil)
        }

        if let error = outcome.error { throw error }
        return outcome.response ?? ""
    }
}

/// In-memory test double for the full LLM service surface (`LLMStreamClient`,
/// `LLMConfigStore`, `LLMUtilityClient`, `HealthCheckable`), backed internally by a
/// ``MockLLMClient`` (`mockClient`) for its streaming behavior.
///
/// Configurable: `mockConfig`/`mockIsConfigured` (configuration state),
/// `mockHealthStatus`/`mockHealthDetails` (health-check responses), `nextResponse`
/// (non-streamed reply text), `nextTags`/`nextGeneratedTitle` (tagging/title-generation
/// stubs), `stubbedStream` (override the stream returned by `chatStream`, bypassing
/// `mockClient`).
/// Call-capture: `generatedTitleInputs` (messages passed to each `generateTitle` call).
public final class MockLLMService: LanguageModel, @unchecked Sendable, HealthCheckable {
    public var mockHealthStatus: HealthStatus = .ok
    public var mockHealthDetails: [String: String]? = ["mock": "true"]

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
            modelTier: request.modelTier
        )
        return LLMStreamResult(stream: stream, rawPrompt: "mock prompt")
    }

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier _: ModelTier
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
