import Foundation
import Logging
import MonadShared
import OpenAI
import Synchronization

// MARK: - Nested Response Types

/// Response structure for the Ollama tags API.
struct OllamaTagsResponse: Codable {
    struct Model: Codable {
        let name: String
    }

    let models: [Model]
}

// MARK: - OllamaClient

public actor OllamaClient {
    private let endpoint: OllamaEndpoint
    private let modelName: String
    private let maxRetries: Int
    private let session: URLSession
    private let logger = Logger.module(named: "ollama-client")

    public init(
        endpoint: String,
        modelName: String,
        timeoutInterval: TimeInterval = 120.0,
        maxRetries: Int = 3
    ) {
        self.endpoint = OllamaEndpoint(rawValue: endpoint)
        self.modelName = modelName
        self.maxRetries = maxRetries

        // Use a custom configuration with longer timeout for local network robustness
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = timeoutInterval * 5
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
        // swiftlint:disable:next line_length
        logger.debug("Initialized OllamaClient: model=\(modelName), endpoint=\(self.endpoint.url.absoluteString), timeout=\(timeoutInterval)s")
    }

    public func chatStream(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]? = nil,
        responseFormat: ChatQuery.ResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) -> AsyncThrowingStream<ChatStreamResult, Error> {
        logger.debug("Ollama chat stream started for model: \(modelName)")

        // Capture dependencies
        let maxRetries = self.maxRetries
        let logger = self.logger

        return AsyncThrowingStream { continuation in
            Task { [self] in
                let hasYielded = Mutex(false)

                do {
                    try await RetryPolicy.retry(
                        maxRetries: maxRetries,
                        shouldRetry: { error in
                            hasYielded.withLock { !$0 } && RetryPolicy.isTransient(error: error)
                        },
                        operation: {
                            let request = try await self.buildRequest(
                                messages: messages,
                                tools: tools,
                                responseFormat: responseFormat,
                                generationParameters: generationParameters
                            )
                            try await self.streamResponse(
                                request: request, hasYielded: hasYielded,
                                logger: logger, continuation: continuation
                            )
                        }
                    )
                    logger.debug("Ollama stream finished normally")
                    continuation.finish()
                } catch {
                    logger.error("Ollama stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Stream Helpers

    private func streamResponse(
        request: URLRequest,
        hasYielded: borrowing Mutex<Bool>,
        logger: Logger,
        continuation: AsyncThrowingStream<ChatStreamResult, Error>.Continuation
    ) async throws {
        logger.debug("Ollama request URL: \(request.url?.absoluteString ?? "nil")")
        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            logger.debug("Ollama request body: \(bodyString)")
        }

        let (stream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.networkError("Invalid response type from Ollama")
        }

        logger.debug("Ollama response status code: \(httpResponse.statusCode)")

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = try await collectErrorBody(from: stream)
            logger.error("Ollama error response body: \(errorBody)")
            throw LLMServiceError.networkError("Ollama API Error: \(httpResponse.statusCode) - \(errorBody)")
        }

        for try await line in stream.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

            if let ollamaResponse = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) {
                if let converted = convertToOpenAI(ollamaResponse) {
                    markYieldedIfNeeded(converted, hasYielded: hasYielded)
                    let chunkContent = converted.choices.first?.delta.content ?? ""
                    logger.debug("Yielding Ollama chunk: \(chunkContent)")
                    continuation.yield(converted)
                }
            }
        }
    }

    private func collectErrorBody(from stream: URLSession.AsyncBytes) async throws -> String {
        var errorBody = ""
        for try await line in stream.lines {
            errorBody += line
        }
        return errorBody
    }

    private nonisolated func markYieldedIfNeeded(_ result: ChatStreamResult, hasYielded: borrowing Mutex<Bool>) {
        if let content = result.choices.first?.delta.content, !content.isEmpty {
            hasYielded.withLock { $0 = true }
        }
        if result.choices.first?.delta.toolCalls != nil {
            hasYielded.withLock { $0 = true }
        }
    }

    private func buildRequest(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]?,
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint.chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let ollamaMessages = messages.map { OllamaMessage(from: $0) }

        var format: String?
        if let responseFormat = responseFormat {
            switch responseFormat {
            case .jsonObject, .jsonSchema:
                format = "json"
            case .text:
                format = nil
            @unknown default:
                format = nil
            }
        }

        let payload = OllamaChatRequest(
            model: modelName,
            messages: ollamaMessages,
            stream: true,
            format: format,
            tools: tools?.map { OllamaTool(from: $0) },
            options: OllamaOptions(from: generationParameters)
        )

        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    // MARK: - OpenAI Conversion

    private nonisolated func convertToOpenAI(_ response: OllamaChatResponse) -> ChatStreamResult? {
        let openAIToolCalls = mapToolCalls(response.message.toolCalls)

        if response.done {
            return buildFinalChunk(response, openAIToolCalls: openAIToolCalls)
        }

        // Skip empty intermediate chunks WITHOUT tool calls
        guard !response.message.content.isEmpty || response.message.toolCalls?.isEmpty == false else {
            return nil
        }

        return buildIntermediateChunk(response, openAIToolCalls: openAIToolCalls)
    }

    private nonisolated func mapToolCalls(
        _ toolCalls: [OllamaToolCall]?
    ) -> [[String: Any]]? {
        toolCalls?.enumerated().map { index, toolCall in
            [
                "index": index,
                "id": UUID().uuidString,
                "type": "function",
                "function": [
                    "name": toolCall.function.name,
                    "arguments": (try? toJsonString(toolCall.function.arguments)) ?? "{}"
                ]
            ]
        }
    }

    private nonisolated func buildFinalChunk(
        _ response: OllamaChatResponse,
        openAIToolCalls: [[String: Any]]?
    ) -> ChatStreamResult? {
        let promptEvalCount = response.promptEvalCount ?? 0
        let evalCount = response.evalCount ?? 0

        var delta: [String: Any] = ["role": "assistant", "content": response.message.content]
        if let toolCalls = openAIToolCalls { delta["tool_calls"] = toolCalls }

        let finishReason = response.message.toolCalls?.isEmpty == false ? "tool_calls" : "stop"
        let jsonDict: [String: Any] = [
            "id": UUID().uuidString,
            "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": response.model,
            "choices": [["index": 0, "delta": delta, "finish_reason": finishReason]],
            "usage": [
                "prompt_tokens": promptEvalCount,
                "completion_tokens": evalCount,
                "total_tokens": promptEvalCount + evalCount
            ]
        ]

        return decodeChunk(jsonDict, context: "final")
    }

    private nonisolated func buildIntermediateChunk(
        _ response: OllamaChatResponse,
        openAIToolCalls: [[String: Any]]?
    ) -> ChatStreamResult? {
        var delta: [String: Any] = ["role": "assistant", "content": response.message.content]
        if let toolCalls = openAIToolCalls { delta["tool_calls"] = toolCalls }

        let jsonDict: [String: Any] = [
            "id": UUID().uuidString,
            "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": response.model,
            "choices": [["index": 0, "delta": delta, "finish_reason": (nil as String?) as Any]]
        ]

        return decodeChunk(jsonDict, context: "intermediate")
    }

    private nonisolated func decodeChunk(_ jsonDict: [String: Any], context: String) -> ChatStreamResult? {
        do {
            let data = try JSONSerialization.data(withJSONObject: jsonDict)
            return try JSONDecoder().decode(ChatStreamResult.self, from: data)
        } catch {
            Logger.module(named: "ollama-client")
                .error("Failed to convert \(context) Ollama response to OpenAI: \(error)")
            return nil
        }
    }

    /// Simple helper
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

    public func fetchAvailableModels() async throws -> [String]? {
        let maxRetries = self.maxRetries
        let endpoint = self.endpoint
        let logger = self.logger

        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            let request = URLRequest(url: endpoint.tagsURL)
            logger.debug("Fetching Ollama models from: \(endpoint.tagsURL.absoluteString)")

            let (data, response) = try await self.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMServiceError.networkError("Invalid response type from Ollama models API")
            }

            logger.debug("Ollama models response status: \(httpResponse.statusCode)")

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw LLMServiceError.networkError("Ollama API Error: \(httpResponse.statusCode)")
            }

            let tagsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            let models = tagsResponse.models.map { $0.name }
            logger.debug("Found \(models.count) Ollama models: \(models.joined(separator: ", "))")
            return models
        }
    }
}
