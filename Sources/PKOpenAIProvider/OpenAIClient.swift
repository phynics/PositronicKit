import Foundation
import Logging
import OpenAI
import PKShared
import PositronicKit
import Synchronization

public actor OpenAIClient: LLMClientProtocol {
    private let client: OpenAI
    private let modelName: String
    private let maxRetries: Int
    private let logger = Logger.module(named: "com.positronickit.openai-client")

    public init(
        apiKey: String,
        modelName: String = "gpt-4o",
        host: String = "api.openai.com",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3
    ) {
        let configuration = OpenAI.Configuration(
            token: apiKey,
            host: host,
            port: port,
            scheme: scheme,
            timeoutInterval: timeoutInterval
        )
        client = OpenAI(configuration: configuration)
        self.modelName = modelName
        self.maxRetries = maxRetries
    }

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let client = self.client
        let logger = self.logger
        let maxRetries = self.maxRetries
        let modelName = self.modelName

        let query = ChatQuery(
            messages: messages.map { $0.toOpenAIMessageParam() },
            model: modelName,
            frequencyPenalty: generationParameters?.frequencyPenalty,
            maxCompletionTokens: generationParameters?.maxTokens,
            parallelToolCalls: tools != nil ? false : nil,
            presencePenalty: generationParameters?.presencePenalty,
            responseFormat: responseFormat?.toOpenAIResponseFormat(),
            seed: generationParameters?.seed,
            temperature: generationParameters?.temperature,
            toolChoice: toolChoice?.toOpenAIToolChoice() ?? (tools != nil ? .auto : nil),
            tools: tools?.map { $0.toOpenAIToolParam() },
            topP: generationParameters?.topP,
            stream: true,
            streamOptions: .init(includeUsage: true)
        )

        return CancellableAsyncThrowingStream.make(of: LLMStreamChunk.self) { continuation in
            let recoveryState = Mutex(LLMToolCallRecoveryState())

            do {
                try await RetryPolicy.retry(
                    maxRetries: maxRetries,
                    shouldRetry: { error in
                        recoveryState.withLock { $0.shouldRetryAfterError } && RetryPolicy.isTransient(error: error)
                    },
                    operation: {
                        let stream: AsyncThrowingStream<ChatStreamResult, Error> = client.chatsStream(query: query)

                        for try await result in stream {
                            if Task.isCancelled { break }
                            recoveryState.withLock {
                                $0.observe(
                                    yieldedContent: !(result.choices.first?.delta.content?.isEmpty ?? true),
                                    streamedToolCalls: result.choices.first?.delta.toolCalls != nil,
                                    finishedWithToolCalls: result.choices.contains(where: { $0.finishReason == .toolCalls })
                                )
                            }

                            continuation.yield(result.toLLMStreamChunk())
                        }

                        if !Task.isCancelled, recoveryState.withLock(\.shouldRecoverToolCalls) {
                            logger.warning("OpenAI stream finished with tool_calls but no streamed delta.toolCalls were received. Recovering tool calls from non-stream response.")
                            var recoveryQuery = query
                            recoveryQuery.stream = false
                            let recoveryResult = try await client.chats(query: recoveryQuery)
                            if !Task.isCancelled, let recoveryChunk = recoveryResult.toLLMToolCallRecoveryChunk() {
                                continuation.yield(recoveryChunk)
                            }
                        }
                    }
                )

                continuation.finish()
            } catch {
                logger.error("OpenAI stream error: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        }
    }

    public func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) async throws -> String {
        let maxRetries = self.maxRetries

        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            let messages = [LLMMessage(role: .user, content: content)]
            var fullContent = ""
            let stream = await self.chatStream(
                messages: messages,
                tools: nil,
                toolChoice: nil,
                responseFormat: responseFormat,
                generationParameters: generationParameters
            )
            for try await result in stream {
                if let delta = result.choices.first?.delta.content {
                    fullContent += delta
                }
            }
            return fullContent
        }
    }

    public func fetchAvailableModels() async throws -> [String]? {
        let maxRetries = self.maxRetries
        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            let models = try await self.client.models()
            return models.data.map { $0.id }
        }
    }
}
