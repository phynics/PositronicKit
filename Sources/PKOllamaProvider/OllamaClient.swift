import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import PKShared
import PKUtilities
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
            // Do not log the raw error body: an Ollama-compatible proxy could echo request
            // headers or other sensitive content in its error responses. `makeError` sanitizes
            // the body before it's embedded in the thrown error, which is the only place it
            // should surface (matches OpenAI/OpenRouter, which never log the raw body — PKR-11).
            throw ProviderHTTPFailure.makeError(
                provider: "Ollama",
                response: httpResponse,
                responseBody: errorBody
            )
        }

        for try await line in stream {
            if Task.isCancelled { break }
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

            do {
                let ollamaResponse = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
                if let converted = convertToChunk(ollamaResponse) {
                    markYieldedIfNeeded(converted, hasYielded: hasYielded)
                    continuation.yield(converted)
                }
            } catch {
                // Previously this was a silent `try?` that dropped malformed/partial NDJSON lines
                // with zero diagnostic trace. OpenAI/OpenRouter handlers log decode failures, so
                // we mirror that here — emitting a warning rather than changing control flow
                // (the line is still skipped, exactly as before). See STAB-12.
                logger.warning("Failed to decode Ollama NDJSON line: \(error.localizedDescription). payloadBytes=\(data.count) payloadHash=\(redactedHash(line))")
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
        if let thinking = result.choices.first?.delta.reasoning, !thinking.isEmpty {
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
        case let .jsonSchema(schema):
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
            messages: messages.map { OllamaMessage(from: $0, logger: logger) },
            stream: true,
            format: format,
            tools: tools?.map { OllamaTool(from: $0) },
            options: OllamaOptions(from: generationParameters)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(payload)
        return request
    }

    private nonisolated func convertToChunk(_ response: OllamaChatResponse) -> LLMStreamChunk? {
        let toolCalls = mapToolCalls(response.message.toolCalls)
        if response.done {
            return buildFinalChunk(response, toolCalls: toolCalls)
        }
        guard !response.message.content.isEmpty
            || response.message.thinking?.isEmpty == false
            || response.message.toolCalls?.isEmpty == false
        else {
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
        let finishReason = mapFinishReason(response).wireValue
        return LLMStreamChunk(
            id: UUID().uuidString,
            model: response.model,
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(
                    role: .assistant,
                    content: response.message.content,
                    reasoning: response.message.thinking,
                    toolCalls: toolCalls
                ),
                finishReason: finishReason
            )],
            usage: LLMTokenUsage(
                promptTokens: promptEvalCount,
                completionTokens: evalCount,
                totalTokens: promptEvalCount + evalCount
            )
        )
    }

    /// Maps Ollama's completion signal onto the shared `FinishReason` vocabulary (PKR-13).
    /// Tool-call detection takes priority (matching prior behavior): it is driven by the
    /// presence of `message.tool_calls`, not by `done_reason`, since Ollama does not
    /// consistently populate `done_reason` with a tool-call-specific value. Otherwise,
    /// `done_reason` is mapped directly — most notably `"length"`, which previously collapsed
    /// into `"stop"` and made truncated responses indistinguishable from normal completions.
    private nonisolated func mapFinishReason(_ response: OllamaChatResponse) -> FinishReason {
        if response.message.toolCalls?.isEmpty == false {
            return .toolCalls
        }
        guard let doneReason = response.doneReason else {
            return .stop
        }
        return FinishReason(wireValue: doneReason)
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
                delta: LLMStreamDelta(
                    role: .assistant,
                    content: response.message.content,
                    reasoning: response.message.thinking,
                    toolCalls: toolCalls
                )
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
