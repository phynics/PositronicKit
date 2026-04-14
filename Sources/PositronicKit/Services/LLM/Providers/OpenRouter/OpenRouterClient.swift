import Foundation
import Logging
import PKShared
import OpenAI
import Synchronization

// MARK: - Response Types

/// Response structure for the OpenRouter models API.
private struct OpenRouterModelsResponse: Codable {
    struct Model: Codable {
        let id: String
    }

    let data: [Model]
}

// MARK: - OpenRouterClient

/// A specialized client for OpenRouter that handles their specific model discovery API
/// and ensures the correct /api/v1 path prefix is used for OpenAI compatibility.
public actor OpenRouterClient {
    private let apiKey: String
    private let modelName: String
    private let endpoint: URL
    private let maxRetries: Int
    private let logger = Logger.module(named: "openrouter-client")
    private let session: URLSession

    public init(
        apiKey: String,
        modelName: String = "openai/gpt-4o",
        host: String = "openrouter.ai",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.maxRetries = maxRetries

        var urlString = "\(scheme)://\(host)"
        if port != 443, port != 80 {
            urlString += ":\(port)"
        }

        if !urlString.contains("/api") {
            urlString += "/api"
        }

        if let url = URL(string: urlString) {
            endpoint = url
        } else {
            logger.warning("Invalid OpenRouter URL '\(urlString)', falling back to default")
            endpoint = URL(string: "https://openrouter.ai/api")!
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutInterval
        session = URLSession(configuration: config)
        logger.debug(
            "Initialized OpenRouterClient: model=\(modelName), endpoint=\(urlString), timeout=\(timeoutInterval)s"
        )
    }

    /// Stream chat responses using direct URLSession bytes stream
    public func chatStream(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]? = nil,
        responseFormat: ChatQuery.ResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) -> AsyncThrowingStream<ChatStreamResult, Error> {
        let endpoint = self.endpoint
        let apiKey = self.apiKey
        let modelName = self.modelName
        let logger = self.logger
        let maxRetries = self.maxRetries

        let chatURL = endpoint.appendingPathComponent("v1/chat/completions")
        logger.debug("OpenRouter chat stream started for model: \(modelName) at \(chatURL.absoluteString)")

        return AsyncThrowingStream { continuation in
            Task {
                let hasYielded = Mutex(false)

                do {
                    try await RetryPolicy.retry(
                        maxRetries: maxRetries,
                        shouldRetry: { error in
                            !hasYielded.withLock { $0 } && RetryPolicy.isTransient(error: error)
                        },
                        operation: {
                            let request = self.buildChatRequest(
                                chatURL: chatURL,
                                apiKey: apiKey,
                                query: ChatQuery(
                                    messages: messages,
                                    model: modelName,
                                    frequencyPenalty: generationParameters?.frequencyPenalty,
                                    maxCompletionTokens: generationParameters?.maxTokens,
                                    presencePenalty: generationParameters?.presencePenalty,
                                    responseFormat: responseFormat,
                                    seed: generationParameters?.seed,
                                    temperature: generationParameters?.temperature,
                                    tools: tools,
                                    topP: generationParameters?.topP,
                                    stream: true,
                                    streamOptions: .init(includeUsage: true)
                                )
                            )
                            try await self.streamChatResponse(
                                request: request, hasYielded: hasYielded,
                                logger: logger, continuation: continuation
                            )
                        }
                    )

                    logger.debug("OpenRouter stream finished normally")
                    continuation.finish()
                } catch {
                    logger.error("OpenRouter stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Stream Helpers

    private nonisolated func buildChatRequest(
        chatURL: URL,
        apiKey: String,
        query: ChatQuery
    ) -> URLRequest {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "https://github.com/monad-assistant/monad",
            forHTTPHeaderField: "HTTP-Referer"
        )
        request.setValue("Monad Assistant", forHTTPHeaderField: "X-Title")

        request.httpBody = try? JSONEncoder().encode(query)
        return request
    }

    private func streamChatResponse(
        request: URLRequest,
        hasYielded: borrowing Mutex<Bool>,
        logger: Logger,
        continuation: AsyncThrowingStream<ChatStreamResult, Error>.Continuation
    ) async throws {
        let (stream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.networkError("Invalid response type from OpenRouter")
        }

        logger.debug("OpenRouter response status: \(httpResponse.statusCode)")

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in stream.lines {
                errorBody += line
            }
            logger.error("OpenRouter error body: \(errorBody)")
            throw LLMServiceError.networkError("OpenRouter API Error: \(httpResponse.statusCode) - \(errorBody)")
        }

        for try await line in stream.lines {
            processSSELine(line, hasYielded: hasYielded, logger: logger, continuation: continuation)
        }
    }

    private nonisolated func processSSELine(
        _ line: String,
        hasYielded: borrowing Mutex<Bool>,
        logger: Logger,
        continuation: AsyncThrowingStream<ChatStreamResult, Error>.Continuation
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.hasPrefix("data: ") else { return }

        let dataString = String(trimmed.dropFirst(6))
        guard dataString != "[DONE]", let data = dataString.data(using: .utf8) else { return }

        do {
            let result = try JSONDecoder().decode(ChatStreamResult.self, from: data)
            if let content = result.choices.first?.delta.content, !content.isEmpty {
                hasYielded.withLock { $0 = true }
            }
            if result.choices.first?.delta.toolCalls != nil {
                hasYielded.withLock { $0 = true }
            }
            continuation.yield(result)
        } catch {
            logger.error(
                // swiftlint:disable:next line_length
                "Failed to decode OpenRouter chunk: \(error.localizedDescription). Raw: \(dataString)"
            )
        }
    }

    /// Send a single message (collects all content from stream)
    public func sendMessage(
        _ content: String,
        responseFormat: ChatQuery.ResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) async throws -> String {
        let maxRetries = self.maxRetries

        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            let messages: [ChatQuery.ChatCompletionMessageParam] = [
                .user(.init(content: .string(content)))
            ]

            var fullContent = ""
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

    /// Fetch available models from OpenRouter's specific models API
    public func fetchAvailableModels() async throws -> [String]? {
        let maxRetries = self.maxRetries
        let endpoint = self.endpoint
        let logger = self.logger

        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            let url = endpoint.appendingPathComponent("v1/models")
            let request = URLRequest(url: url)
            logger.debug("Fetching OpenRouter models from: \(url.absoluteString)")

            let (data, response) = try await self.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMServiceError.networkError("Invalid response type from OpenRouter models API")
            }

            logger.debug("OpenRouter models response status: \(httpResponse.statusCode)")

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw LLMServiceError.networkError("OpenRouter API Error: \(httpResponse.statusCode)")
            }

            let modelsResponse = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
            let models = modelsResponse.data.map { $0.id }.sorted()
            logger.debug("Found \(models.count) OpenRouter models")
            return models
        }
    }
}
