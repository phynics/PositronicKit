import Foundation
import Logging
import PKShared
import OpenAI
import Synchronization

/// A wrapper around the OpenAI SDK that provides a clean interface for the PositronicKit Assistant
public actor OpenAIClient {
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
        // swiftlint:disable:next line_length
        logger.debug("Initialized OpenAIClient: model=\(modelName), host=\(host), port=\(port), scheme=\(scheme), timeout=\(timeoutInterval)s")
    }

    /// Stream chat responses
    public func chatStream(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]? = nil,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam? = nil,
        responseFormat: ChatQuery.ResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) -> AsyncThrowingStream<ChatStreamResult, Error> {
        // Capture dependencies locally to avoid actor isolation issues in the stream closure
        let client = self.client
        let logger = self.logger
        let maxRetries = self.maxRetries
        let modelName = self.modelName

        let query = ChatQuery(
            messages: messages,
            model: modelName,
            frequencyPenalty: generationParameters?.frequencyPenalty,
            maxCompletionTokens: generationParameters?.maxTokens,
            parallelToolCalls: tools != nil ? false : nil,
            presencePenalty: generationParameters?.presencePenalty,
            responseFormat: responseFormat,
            seed: generationParameters?.seed,
            temperature: generationParameters?.temperature,
            toolChoice: toolChoice ?? (tools != nil ? .auto : nil),
            tools: tools,
            topP: generationParameters?.topP,
            stream: true,
            streamOptions: .init(includeUsage: true)
        )

        logger.debug("Starting chat stream with model: \(modelName)")
        if let tools = tools {
            logger.debug("Tools provided: \(tools.map { $0.function.name }.joined(separator: ", "))")
        }

        return AsyncThrowingStream { continuation in
            Task {
                let hasYielded = Mutex(false)

                do {
                    try await RetryPolicy.retry(
                        maxRetries: maxRetries,
                        shouldRetry: { error in
                            // Only retry if we haven't started yielding data to avoid duplication
                            // and if the error is transient
                            !hasYielded.withLock { $0 } && RetryPolicy.isTransient(error: error)
                        },
                        operation: {
                            // Create a new stream for each attempt
                            let stream: AsyncThrowingStream<ChatStreamResult, Error> = client.chatsStream(query: query)

                            for try await result in stream {
                                if let delta = result.choices.first?.delta.content {
                                    if !delta.isEmpty {
                                        hasYielded.withLock { $0 = true }
                                        logger.debug("Yielding OpenAI chunk (\(delta.count) chars)")
                                    }
                                }
                                // Also mark as yielded if we get tool calls or other content
                                if result.choices.first?.delta.toolCalls != nil {
                                    hasYielded.withLock { $0 = true }
                                }

                                continuation.yield(result)
                            }
                        }
                    )

                    logger.debug("OpenAI stream finished normally")
                    continuation.finish()
                } catch {
                    logger.error("OpenAI stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Convenience Extensions

public extension OpenAIClient {
    /// Simple helper to send a user message via stream (collects all content)
    func sendMessage(
        _ content: String,
        responseFormat: ChatQuery.ResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) async throws -> String {
        // We wrap the entire operation in retry because for a non-streaming result,
        // we can retry even if it failed midway (as we discard the partial result).
        // Capture maxRetries to avoid actor isolation issues in closure
        let maxRetries = self.maxRetries

        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            let messages: [ChatQuery.ChatCompletionMessageParam] = [
                .user(.init(content: .string(content)))
            ]

            var fullContent = ""
            // We use the chatStream implementation, but here we don't mind if it fails mid-stream
            // because we are collecting it. However, chatStream's internal retry logic
            // stops retrying if it yielded. So if chatStream throws mid-stream,
            // THIS retry block will catch it and retry the whole thing.
            let stream = await self.chatStream(
                messages: messages,
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

    /// Fetch available models from the service
    func fetchAvailableModels() async throws -> [String]? {
        let maxRetries = self.maxRetries
        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            let models = try await self.client.models()
            return models.data.map { $0.id }
        }
    }
}
