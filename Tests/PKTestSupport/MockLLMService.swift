import Foundation
import PKShared
import PKUtilities
import PositronicKit
import Synchronization

/// Complete immutable capture of one low-level streaming request.
///
/// Histories append this record before the mock returns a configured error, never-finishing
/// stream, delegated stream, or service-level stubbed stream.
public struct MockLLMChatCapture: Sendable {
    public let messages: [LLMMessage]
    public let tools: [LLMToolDefinition]?
    public let toolChoice: LLMToolChoice?
    public let responseFormat: LLMResponseFormat?
    public let generationParameters: GenerationParameters?
    public let modelTier: ModelTier
}

/// Complete immutable capture of one non-streaming send request.
///
/// `MockLLMClient` appends this record before surfacing an injected send error.
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
///
/// Each call atomically captures its inputs and selects one plan in this order: a matching
/// never-finishing call index, configured error, one `nextRawStreamChunks` entry, one
/// `nextChunks` entry, one `nextResponses` entry, then `nextResponse`. Scripts are assigned in
/// mutex-admission order, which need not match task creation order under concurrency. A normal
/// text plan consumes at most one `nextToolCalls` entry; the earlier plans do not consume it.
///
/// `chatCaptureHistory` and `sendMessageCaptureHistory` retain complete request records,
/// including calls that later fail; the legacy `last…` fields and `messageHistory` remain
/// available. No mutex is held while a stream sleeps, yields, or waits for cancellation.
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

    /// Clock used before each finite raw or text chunk when `nextStreamWait` is set.
    /// Inject `ImmediateClock` for instant execution, or use the default `ContinuousClock`.
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

    /// Queued text-chunk scripts. Raw scripts take precedence; these take precedence over
    /// `nextResponses` and `nextResponse`.
    public var nextChunks: [[String]] {
        get { state.withLock { $0.nextChunks } }
        set { state.withLock { $0.nextChunks = newValue } }
    }

    /// Queued raw-chunk scripts for full control over tool-call delta fragmentation.
    /// Raw scripts take precedence over every content-response script.
    public var nextRawStreamChunks: [[LLMStreamChunk]] {
        get { state.withLock { $0.nextRawStreamChunks } }
        set { state.withLock { $0.nextRawStreamChunks = newValue } }
    }

    /// Optional clock-driven delay before each finite raw or text chunk.
    /// Stream termination cancels the producer task, and cancellation is checked around the sleep.
    public var nextStreamWait: TimeInterval? {
        get { state.withLock { $0.nextStreamWait } }
        set { state.withLock { $0.nextStreamWait = newValue } }
    }

    public var lastChatCapture: MockLLMChatCapture? {
        state.withLock { $0.lastChatCapture }
    }

    /// Complete low-level chat captures in atomic admission order, including failing and
    /// never-finishing calls.
    public var chatCaptureHistory: [MockLLMChatCapture] {
        state.withLock { $0.chatCaptureHistory }
    }

    public var lastSendMessageCapture: MockLLMSendMessageCapture? {
        state.withLock { $0.lastSendMessageCapture }
    }

    /// Complete non-streaming send captures in atomic admission order, including injected errors.
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

            struct RawStreamContext: Sendable {
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

            struct StreamContext: Sendable {
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
///
/// `chatCaptureHistory`, `sendMessageCaptureHistory`, `chatRequestHistory`, and
/// `modelTierHistory` capture calls before delegation or `stubbedStream` selection, so errors and
/// stubs remain observable; `generatedTitleInputs` records every title request. The service starts
/// configured with `.openAI`; `updateConfiguration` and successful import mark it configured,
/// while `clearConfiguration` restores `.openAI` and marks it unconfigured. Export/import performs
/// JSON work after taking a state snapshot and before committing decoded state;
/// `loadConfiguration` and `restoreFromBackup` are no-op hooks. No lock crosses JSON work,
/// delegated streaming, stream iteration, or caller-provided execution.
public final class MockLLMService: LanguageModel, HealthCheckable {
    private struct State: Sendable {
        var mockHealthStatus: HealthStatus = .ok
        var mockHealthDetails: [String: String]? = ["mock": "true"]
        var mockIsConfigured = true
        var mockConfig: LLMConfiguration = .openAI
        var nextResponse = ""
        var nextTags: [String] = []
        var nextGeneratedTitle = "Mock Title"
        var generatedTitleInputs: [[Message]] = []
        var mockClient = MockLLMClient()
        var stubbedStream: AsyncThrowingStream<LLMStreamChunk, Error>?
        var lastChatRequest: LLMChatRequest?
        var chatRequestHistory: [LLMChatRequest] = []
        var lastModelTier: ModelTier?
        var modelTierHistory: [ModelTier] = []
        var lastChatCapture: MockLLMChatCapture?
        var chatCaptureHistory: [MockLLMChatCapture] = []
        var lastSendMessageCapture: MockLLMSendMessageCapture?
        var sendMessageCaptureHistory: [MockLLMSendMessageCapture] = []
    }

    private let state = Mutex(State())

    public var mockHealthStatus: HealthStatus {
        get { state.withLock { $0.mockHealthStatus } }
        set { state.withLock { $0.mockHealthStatus = newValue } }
    }

    public var mockHealthDetails: [String: String]? {
        get { state.withLock { $0.mockHealthDetails } }
        set { state.withLock { $0.mockHealthDetails = newValue } }
    }

    public func getHealthDetails() async -> [String: String]? {
        state.withLock { $0.mockHealthDetails }
    }

    public func checkHealth() async -> HealthStatus {
        state.withLock { $0.mockHealthStatus }
    }

    public var mockIsConfigured: Bool {
        get { state.withLock { $0.mockIsConfigured } }
        set { state.withLock { $0.mockIsConfigured = newValue } }
    }

    public var isConfigured: Bool {
        get async { state.withLock { $0.mockIsConfigured } }
    }

    public var configuration: LLMConfiguration {
        get async { state.withLock { $0.mockConfig } }
    }

    public var mockConfig: LLMConfiguration {
        get { state.withLock { $0.mockConfig } }
        set { state.withLock { $0.mockConfig = newValue } }
    }

    public var nextResponse: String {
        get { state.withLock { $0.nextResponse } }
        set { state.withLock { $0.nextResponse = newValue } }
    }

    public var nextTags: [String] {
        get { state.withLock { $0.nextTags } }
        set { state.withLock { $0.nextTags = newValue } }
    }

    public var nextGeneratedTitle: String {
        get { state.withLock { $0.nextGeneratedTitle } }
        set { state.withLock { $0.nextGeneratedTitle = newValue } }
    }

    public var generatedTitleInputs: [[Message]] {
        get { state.withLock { $0.generatedTitleInputs } }
        set { state.withLock { $0.generatedTitleInputs = newValue } }
    }

    public var mockClient: MockLLMClient {
        get { state.withLock { $0.mockClient } }
        set { state.withLock { $0.mockClient = newValue } }
    }

    /// Overrides the stream returned by `chatStream`. The request is still captured first.
    public var stubbedStream: AsyncThrowingStream<LLMStreamChunk, Error>? {
        get { state.withLock { $0.stubbedStream } }
        set { state.withLock { $0.stubbedStream = newValue } }
    }

    public var lastChatRequest: LLMChatRequest? {
        state.withLock { $0.lastChatRequest }
    }

    /// Complete high-level context requests in atomic admission order.
    public var chatRequestHistory: [LLMChatRequest] {
        state.withLock { $0.chatRequestHistory }
    }

    public var lastModelTier: ModelTier? {
        state.withLock { $0.lastModelTier }
    }

    /// Actual model tiers requested by low-level and high-level chat calls.
    public var modelTierHistory: [ModelTier] {
        state.withLock { $0.modelTierHistory }
    }

    public var lastChatCapture: MockLLMChatCapture? {
        state.withLock { $0.lastChatCapture }
    }

    /// Complete service-level chat captures, including calls returning `stubbedStream`.
    public var chatCaptureHistory: [MockLLMChatCapture] {
        state.withLock { $0.chatCaptureHistory }
    }

    public var lastSendMessageCapture: MockLLMSendMessageCapture? {
        state.withLock { $0.lastSendMessageCapture }
    }

    /// Complete service-level non-streaming send captures.
    public var sendMessageCaptureHistory: [MockLLMSendMessageCapture] {
        state.withLock { $0.sendMessageCaptureHistory }
    }

    public init() {}

    public func loadConfiguration() async {}

    public func updateConfiguration(_ config: LLMConfiguration) async throws {
        state.withLock {
            $0.mockConfig = config
            $0.mockIsConfigured = true
        }
    }

    public func clearConfiguration() async {
        state.withLock {
            $0.mockConfig = .openAI
            $0.mockIsConfigured = false
        }
    }

    public func restoreFromBackup() async throws {}

    public func exportConfiguration() async throws -> Data {
        let configuration = state.withLock { $0.mockConfig }
        return try JSONEncoder().encode(configuration)
    }

    public func importConfiguration(from data: Data) async throws {
        let configuration = try JSONDecoder().decode(LLMConfiguration.self, from: data)
        state.withLock {
            $0.mockConfig = configuration
            $0.mockIsConfigured = true
        }
    }

    public func sendMessage(_ content: String) async throws -> String {
        state.withLock { state in
            let capture = MockLLMSendMessageCapture(
                content: content,
                responseFormat: nil,
                generationParameters: nil,
                useUtilityModel: false
            )
            state.lastSendMessageCapture = capture
            state.sendMessageCaptureHistory.append(capture)
            return state.nextResponse
        }
    }

    public func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel: Bool
    ) async throws -> String {
        state.withLock { state in
            let capture = MockLLMSendMessageCapture(
                content: content,
                responseFormat: responseFormat,
                generationParameters: generationParameters,
                useUtilityModel: useUtilityModel
            )
            state.lastSendMessageCapture = capture
            state.sendMessageCaptureHistory.append(capture)
            return state.nextResponse
        }
    }

    public func chatStreamWithContext(_ request: LLMChatRequest) async throws -> LLMStreamResult {
        state.withLock {
            $0.lastChatRequest = request
            $0.chatRequestHistory.append(request)
        }
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
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let target = state.withLock { state -> (
            stubbed: AsyncThrowingStream<LLMStreamChunk, Error>?,
            client: MockLLMClient
        ) in
            let capture = MockLLMChatCapture(
                messages: messages,
                tools: tools,
                toolChoice: toolChoice,
                responseFormat: responseFormat,
                generationParameters: generationParameters,
                modelTier: modelTier
            )
            state.lastModelTier = modelTier
            state.modelTierHistory.append(modelTier)
            state.lastChatCapture = capture
            state.chatCaptureHistory.append(capture)
            return (state.stubbedStream, state.mockClient)
        }

        if let stubbed = target.stubbed {
            return stubbed
        }
        return await target.client.chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters
        )
    }

    public func generateTags(for _: String) async throws -> [String] {
        let tags = state.withLock { $0.nextTags }
        return tags.map { $0.lowercased() }
    }

    public func generateTitle(for messages: [Message]) async throws -> String {
        let scriptedTitle = state.withLock { state in
            state.generatedTitleInputs.append(messages)
            return state.nextGeneratedTitle
        }
        let title = scriptedTitle
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
