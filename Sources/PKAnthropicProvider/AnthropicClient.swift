import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import PKShared
import PKUtilities

/// Native Anthropic Messages API client (`POST /v1/messages`).
///
/// Decodes the event-based SSE stream (`message_start` / `content_block_start` /
/// `content_block_delta` / `content_block_stop` / `message_delta` / `message_stop`) into
/// transport-neutral `LLMStreamChunk`s (PKINT-001).
///
/// Structured output (`LLMResponseFormat.jsonObject`/`.jsonSchema`) is NOT supported by the
/// Messages API — there is no `response_format` equivalent. Requests carrying one are sent
/// without it and a warning is logged; callers needing schema-constrained output should use
/// tool calling (a forced tool with the desired `input_schema`) instead.
public actor AnthropicClient: LLMClientProtocol {
    /// The Messages API requires `max_tokens`; used when `GenerationParameters.maxTokens` is nil.
    public static let defaultMaxTokens = 4096
    static let apiVersion = "2023-06-01"

    private let apiKey: String
    private let modelName: String
    private let endpoint: URL
    private let maxRetries: Int
    private let timeoutInterval: TimeInterval
    private let transport: any ProviderHTTPTransport
    private let logger = Logger.module(named: "anthropic-client")

    /// Anthropic SSE payloads are snake_case (`content_block`, `partial_json`, `stop_reason`).
    private static let eventDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public init(
        apiKey: String,
        modelName: String = "claude-sonnet-4-5",
        host: String = "api.anthropic.com",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3
    ) {
        self.init(
            apiKey: apiKey,
            modelName: modelName,
            host: host,
            port: port,
            scheme: scheme,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            transport: URLSessionProviderHTTPTransport(timeoutIntervalForRequest: timeoutInterval)
        )
    }

    package init(
        apiKey: String,
        modelName: String = "claude-sonnet-4-5",
        host: String = "api.anthropic.com",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        transport: any ProviderHTTPTransport
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
        self.transport = transport

        var urlString = "\(scheme)://\(host)"
        if port != 443, port != 80 { urlString += ":\(port)" }
        endpoint = URL(string: urlString) ?? URL(string: "https://api.anthropic.com")!
    }

    // MARK: - Streaming

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let maxRetries = self.maxRetries
        let logger = self.logger

        return CancellableAsyncThrowingStream.make(of: LLMStreamChunk.self) { continuation in
            // Duplicate-content retry gate (PKR-5/PKCR-005): once anything has been yielded
            // to the consumer, a transient transport error must NOT trigger a retry, or the
            // caller would observe duplicated content.
            let gate = DuplicateContentRetryGate()

            do {
                try validateLLMMessageHistory(messages)
                try await RetryPolicy.retry(
                    maxRetries: maxRetries,
                    shouldRetry: { gate.shouldRetry(error: $0) },
                    operation: {
                        let request = try self.buildChatRequest(
                            messages: messages,
                            tools: tools,
                            toolChoice: toolChoice,
                            responseFormat: responseFormat,
                            generationParameters: generationParameters
                        )
                        try await self.streamResponse(
                            request: request,
                            gate: gate,
                            logger: logger,
                            continuation: continuation
                        )
                    }
                )
                continuation.finish()
            } catch {
                logger.error("Anthropic stream error: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        }
    }

    private func streamResponse(
        request: URLRequest,
        gate: DuplicateContentRetryGate,
        logger: Logger,
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) async throws {
        let (stream, response) = try await transport.lines(for: request)

        let httpResponse = try HTTPHelpers.ensureHTTPResponse(response, provider: "Anthropic")
        if !(200 ... 299).contains(httpResponse.statusCode) {
            let errorBody = try await LimitedErrorBodyCollector.collect(from: stream)
            try HTTPHelpers.ensureSuccessStatus(
                httpResponse,
                provider: "Anthropic",
                body: Data(errorBody.utf8)
            )
        }

        var state = AnthropicStreamState(fallbackModel: modelName)
        for try await line in stream {
            if Task.isCancelled { break }
            try processSSELine(
                line,
                state: &state,
                gate: gate,
                logger: logger,
                continuation: continuation
            )
        }
    }

    private nonisolated func processSSELine(
        _ line: String,
        state: inout AnthropicStreamState,
        gate: DuplicateContentRetryGate,
        logger: Logger,
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) throws {
        guard let data = HTTPHelpers.extractSSEData(from: line) else { return }
        let dataString = String(decoding: data, as: UTF8.self)

        let event: AnthropicStreamEvent
        do {
            event = try Self.eventDecoder.decode(AnthropicStreamEvent.self, from: data)
        } catch {
            logger.error(
                "Malformed Anthropic SSE frame: \(error.localizedDescription). payloadBytes=\(data.count) payloadHash=\(redactedHash(dataString))"
            )
            throw error
        }

        if event.type == "error" {
            let message = event.error?.message ?? "unknown"
            let type = event.error?.type ?? "error"
            throw LLMServiceError.networkError(
                "Anthropic stream error event (\(type)): \(ProviderHTTPFailure.sanitize(message))"
            )
        }

        guard let chunk = state.consume(event) else { return }
        gate.markYieldedIfNeeded(chunk)
        continuation.yield(chunk)
    }

    // MARK: - Request building

    private nonisolated func buildChatRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) throws -> URLRequest {
        switch responseFormat {
        case .jsonObject, .jsonSchema:
            // Documented non-support: the Messages API has no `response_format` equivalent.
            logger.warning(
                "Anthropic does not support structured output (response_format); the request is sent without it. Use tool calling with a forced tool for schema-constrained output."
            )
        case .text, .none:
            break
        }

        if generationParameters?.frequencyPenalty != nil
            || generationParameters?.presencePenalty != nil
            || generationParameters?.seed != nil
        {
            logger.debug(
                "Anthropic ignores frequencyPenalty/presencePenalty/seed (no Messages API equivalents)."
            )
        }

        let (system, converted) = try AnthropicMessageConversion.convert(messages: messages, logger: logger)
        let effectiveTools = toolChoice == .some(LLMToolChoice.none) ? nil : tools
        let payload = AnthropicChatRequest(
            model: modelName,
            maxTokens: generationParameters?.maxTokens ?? Self.defaultMaxTokens,
            system: system,
            messages: converted,
            tools: effectiveTools?.map(AnthropicTool.init),
            toolChoice: mapToolChoice(toolChoice ?? (tools != nil ? .auto : nil)),
            temperature: generationParameters?.temperature,
            topP: generationParameters?.topP,
            stream: true
        )

        var request = URLRequest(url: endpoint.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(payload)
        return request
    }

    private nonisolated func mapToolChoice(_ choice: LLMToolChoice?) -> AnthropicToolChoice? {
        switch choice {
        case nil, .some(.none): return nil
        case .some(.auto): return .auto
        case let .some(.function(name)): return .tool(name)
        }
    }

    // MARK: - Convenience

    public func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) async throws -> String {
        let stream = await self.chatStream(
            messages: [LLMMessage(role: .user, content: content)],
            tools: nil,
            toolChoice: nil,
            responseFormat: responseFormat,
            generationParameters: generationParameters
        )
        return try await accumulateStreamContent(from: stream)
    }

    public func fetchAvailableModels() async throws -> [String]? {
        let maxRetries = self.maxRetries
        let endpoint = self.endpoint
        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/models"))
            request.timeoutInterval = self.timeoutInterval
            request.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
            let (data, response) = try await self.transport.data(for: request)
            let httpResponse = try HTTPHelpers.ensureHTTPResponse(response, provider: "Anthropic models API")
            try HTTPHelpers.ensureSuccessStatus(httpResponse, provider: "Anthropic", body: data)
            let modelsResponse = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            return modelsResponse.data.map { $0.id }.sorted()
        }
    }
}
