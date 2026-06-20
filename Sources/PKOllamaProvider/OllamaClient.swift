import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import PKShared
import PositronicKit
import Synchronization

struct OllamaTagsResponse: Codable {
    struct Model: Codable {
        let name: String
    }

    let models: [Model]
}

public actor OllamaClient: LLMClientProtocol {
    private let endpoint: OllamaEndpoint
    private let modelName: String
    private let maxRetries: Int
    private let timeoutInterval: TimeInterval
    private let transport: any ProviderHTTPTransport
    private let logger = Logger.module(named: "ollama-client")

    public init(
        endpoint: String,
        modelName: String,
        timeoutInterval: TimeInterval = 120.0,
        maxRetries: Int = 3
    ) {
        self.init(
            endpoint: endpoint,
            modelName: modelName,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            transport: URLSessionProviderHTTPTransport(
                timeoutIntervalForRequest: timeoutInterval,
                timeoutIntervalForResource: timeoutInterval * 5,
                waitsForConnectivity: true
            )
        )
    }

    package init(
        endpoint: String,
        modelName: String,
        timeoutInterval: TimeInterval = 120.0,
        maxRetries: Int = 3,
        transport: any ProviderHTTPTransport
    ) {
        self.endpoint = OllamaEndpoint(rawValue: endpoint)
        self.modelName = modelName
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
        self.transport = transport
    }

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let maxRetries = self.maxRetries
        let logger = self.logger

        return CancellableAsyncThrowingStream.make(of: LLMStreamChunk.self) { continuation in
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
                            request: request,
                            hasYielded: hasYielded,
                            logger: logger,
                            continuation: continuation
                        )
                    }
                )
                continuation.finish()
            } catch {
                logger.error("Ollama stream error: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        }
    }

    private func streamResponse(
        request: URLRequest,
        hasYielded: borrowing Mutex<Bool>,
        logger: Logger,
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) async throws {
        let (stream, response) = try await transport.lines(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.networkError("Invalid response type from Ollama")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = try await collectErrorBody(from: stream)
            logger.error("Ollama error response body: \(errorBody)")
            throw ProviderHTTPFailure.makeError(
                provider: "Ollama",
                response: httpResponse,
                responseBody: errorBody
            )
        }

        for try await line in stream {
            if Task.isCancelled { break }
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

            if let ollamaResponse = try? JSONDecoder().decode(OllamaChatResponse.self, from: data),
               let converted = convertToChunk(ollamaResponse) {
                markYieldedIfNeeded(converted, hasYielded: hasYielded)
                continuation.yield(converted)
            }
        }
    }

    private func collectErrorBody(from stream: AsyncThrowingStream<String, Error>) async throws -> String {
        try await LimitedErrorBodyCollector.collect(from: stream)
    }

    private nonisolated func markYieldedIfNeeded(_ result: LLMStreamChunk, hasYielded: borrowing Mutex<Bool>) {
        if let content = result.choices.first?.delta.content, !content.isEmpty {
            hasYielded.withLock { $0 = true }
        }
        if result.choices.first?.delta.toolCalls != nil {
            hasYielded.withLock { $0 = true }
        }
    }

    private func buildRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint.chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let format: OllamaResponseFormat?
        switch responseFormat {
        case .jsonObject:
            format = .jsonObject
        case .jsonSchema(let schema):
            if let schema = schema.schema {
                format = .jsonSchema(schema)
            } else {
                format = .jsonObject
            }
        default:
            format = nil
        }

        let payload = OllamaChatRequest(
            model: modelName,
            messages: messages.map { OllamaMessage(from: $0) },
            stream: true,
            format: format,
            tools: tools?.map { OllamaTool(from: $0) },
            options: OllamaOptions(from: generationParameters)
        )

        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private nonisolated func convertToChunk(_ response: OllamaChatResponse) -> LLMStreamChunk? {
        let toolCalls = mapToolCalls(response.message.toolCalls)
        if response.done {
            return buildFinalChunk(response, toolCalls: toolCalls)
        }
        guard !response.message.content.isEmpty || response.message.toolCalls?.isEmpty == false else {
            return nil
        }
        return buildIntermediateChunk(response, toolCalls: toolCalls)
    }

    private nonisolated func mapToolCalls(_ toolCalls: [OllamaToolCall]?) -> [LLMToolCallDelta]? {
        toolCalls?.enumerated().map { index, toolCall in
            LLMToolCallDelta(
                index: index,
                id: UUID().uuidString,
                function: LLMToolCallDeltaFunction(
                    name: toolCall.function.name,
                    arguments: (try? toJsonString(toolCall.function.arguments)) ?? "{}"
                )
            )
        }
    }

    private nonisolated func buildFinalChunk(
        _ response: OllamaChatResponse,
        toolCalls: [LLMToolCallDelta]?
    ) -> LLMStreamChunk {
        let promptEvalCount = response.promptEvalCount ?? 0
        let evalCount = response.evalCount ?? 0
        let finishReason = response.message.toolCalls?.isEmpty == false ? "tool_calls" : "stop"
        return LLMStreamChunk(
            id: UUID().uuidString,
            model: response.model,
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(role: .assistant, content: response.message.content, toolCalls: toolCalls),
                finishReason: finishReason
            )],
            usage: LLMTokenUsage(
                promptTokens: promptEvalCount,
                completionTokens: evalCount,
                totalTokens: promptEvalCount + evalCount
            )
        )
    }

    private nonisolated func buildIntermediateChunk(
        _ response: OllamaChatResponse,
        toolCalls: [LLMToolCallDelta]?
    ) -> LLMStreamChunk {
        LLMStreamChunk(
            id: UUID().uuidString,
            model: response.model,
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(role: .assistant, content: response.message.content, toolCalls: toolCalls)
            )]
        )
    }

    public func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) async throws -> String {
        let maxRetries = self.maxRetries
        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            var fullContent = ""
            let stream = await self.chatStream(
                messages: [LLMMessage(role: .user, content: content)],
                tools: nil,
                toolChoice: nil,
                responseFormat: responseFormat,
                generationParameters: generationParameters
            )
            for try await result in stream {
                if let delta = result.choices.first?.delta.content { fullContent += delta }
            }
            return fullContent
        }
    }

    public func fetchAvailableModels() async throws -> [String]? {
        let maxRetries = self.maxRetries
        let endpoint = self.endpoint
        let logger = self.logger

        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            logger.debug("Fetching Ollama models from: \(endpoint.tagsURL.absoluteString)")

            var request = URLRequest(url: endpoint.tagsURL)
            request.timeoutInterval = self.timeoutInterval
            let (data, response) = try await self.transport.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMServiceError.networkError("Invalid response type from Ollama models API")
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw ProviderHTTPFailure.makeError(
                    provider: "Ollama",
                    response: httpResponse,
                    responseBody: ProviderHTTPFailure.sanitize(String(data: data, encoding: .utf8) ?? "")
                )
            }

            let tagsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return tagsResponse.models.map { $0.name }
        }
    }
}
