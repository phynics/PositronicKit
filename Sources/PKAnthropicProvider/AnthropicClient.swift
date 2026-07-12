import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import PKShared
import PKUtilities
import PositronicKit
import Synchronization

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
            // Duplicate-content retry gate (PKR-5): once anything has been yielded to the
            // consumer, a transient transport error must NOT trigger a retry, or the caller
            // would observe duplicated content.
            let hasYielded = Mutex(false)

            do {
                try await RetryPolicy.retry(
                    maxRetries: maxRetries,
                    shouldRetry: { error in
                        hasYielded.withLock { !$0 } && RetryPolicy.isTransient(error: error)
                    },
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
                            hasYielded: hasYielded,
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
        hasYielded: borrowing Mutex<Bool>,
        logger: Logger,
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) async throws {
        let (stream, response) = try await transport.lines(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.networkError("Invalid response type from Anthropic")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = try await LimitedErrorBodyCollector.collect(from: stream)
            // Never log the raw error body — it is sanitized before being embedded in the
            // thrown error, which is the only place it surfaces (PKR-11).
            throw ProviderHTTPFailure.makeError(
                provider: "Anthropic",
                response: httpResponse,
                responseBody: errorBody
            )
        }

        var state = AnthropicStreamState(fallbackModel: modelName)
        for try await line in stream {
            if Task.isCancelled { break }
            try processSSELine(
                line,
                state: &state,
                hasYielded: hasYielded,
                logger: logger,
                continuation: continuation
            )
        }
    }

    private nonisolated func processSSELine(
        _ line: String,
        state: inout AnthropicStreamState,
        hasYielded: borrowing Mutex<Bool>,
        logger: Logger,
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) throws {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // The `event:` line duplicates the payload's `type` field; only `data:` lines carry JSON.
        guard !trimmed.isEmpty, trimmed.hasPrefix("data: ") else { return }
        let dataString = String(trimmed.dropFirst(6))
        guard let data = dataString.data(using: .utf8) else { return }

        let event: AnthropicStreamEvent
        do {
            event = try Self.eventDecoder.decode(AnthropicStreamEvent.self, from: data)
        } catch {
            logger.warning(
                "Failed to decode Anthropic SSE event: \(error.localizedDescription). payloadBytes=\(data.count) payloadHash=\(redactedHash(dataString))"
            )
            return
        }

        if event.type == "error" {
            let message = event.error?.message ?? "unknown"
            let type = event.error?.type ?? "error"
            throw LLMServiceError.networkError(
                "Anthropic stream error event (\(type)): \(ProviderHTTPFailure.sanitize(message))"
            )
        }

        guard let chunk = state.consume(event) else { return }
        markYieldedIfNeeded(chunk, hasYielded: hasYielded)
        continuation.yield(chunk)
    }

    private nonisolated func markYieldedIfNeeded(
        _ chunk: LLMStreamChunk,
        hasYielded: borrowing Mutex<Bool>
    ) {
        let delta = chunk.choices.first?.delta
        if delta?.content?.isEmpty == false || delta?.reasoning?.isEmpty == false || delta?.toolCalls != nil {
            hasYielded.withLock { $0 = true }
        }
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

        let (system, converted) = AnthropicMessageConversion.convert(messages: messages, logger: logger)
        let payload = AnthropicChatRequest(
            model: modelName,
            maxTokens: generationParameters?.maxTokens ?? Self.defaultMaxTokens,
            system: system,
            messages: converted,
            tools: tools?.map(AnthropicTool.init),
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
        case .none: return nil
        case .auto: return .auto
        case let .function(name): return .tool(name)
        }
    }

    // MARK: - Convenience

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
            for try await chunk in stream {
                if let delta = chunk.choices.first?.delta.content { fullContent += delta }
            }
            return fullContent
        }
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
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMServiceError.networkError("Invalid response type from Anthropic models API")
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw ProviderHTTPFailure.makeError(
                    provider: "Anthropic",
                    response: httpResponse,
                    responseBody: ProviderHTTPFailure.sanitize(String(data: data, encoding: .utf8) ?? "")
                )
            }
            let modelsResponse = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            return modelsResponse.data.map { $0.id }.sorted()
        }
    }
}

// MARK: - Stream state

/// Accumulates cross-event state while mapping the Anthropic event stream to `LLMStreamChunk`s.
///
/// Tool-use inputs stream as `input_json_delta.partial_json` fragments scoped to a content
/// block `index`; this state assigns each tool_use block an ordinal (the `LLMToolCallDelta.index`)
/// so downstream accumulation reassembles arguments exactly like the OpenAI-family adapters.
struct AnthropicStreamState {
    let fallbackModel: String
    private(set) var messageID = ""
    private(set) var model: String
    private var inputTokens: Int?
    private var cachedTokens: Int?
    private var toolOrdinalByBlockIndex: [Int: Int] = [:]
    private var nextToolOrdinal = 0

    init(fallbackModel: String) {
        self.fallbackModel = fallbackModel
        model = fallbackModel
    }

    mutating func consume(_ event: AnthropicStreamEvent) -> LLMStreamChunk? {
        switch event.type {
        case "message_start":
            if let message = event.message {
                messageID = message.id
                model = message.model
                inputTokens = message.usage?.inputTokens
                cachedTokens = message.usage?.cacheReadInputTokens
            }
            return nil

        case "content_block_start":
            guard let block = event.contentBlock, block.type == "tool_use",
                  let blockIndex = event.index
            else { return nil }
            let ordinal = nextToolOrdinal
            nextToolOrdinal += 1
            toolOrdinalByBlockIndex[blockIndex] = ordinal
            return makeChunk(delta: LLMStreamDelta(
                role: .assistant,
                toolCalls: [LLMToolCallDelta(
                    index: ordinal,
                    id: block.id,
                    function: LLMToolCallDeltaFunction(name: block.name, arguments: "")
                )]
            ))

        case "content_block_delta":
            guard let delta = event.delta else { return nil }
            switch delta.type {
            case "text_delta":
                guard let text = delta.text, !text.isEmpty else { return nil }
                return makeChunk(delta: LLMStreamDelta(role: .assistant, content: text))
            case "thinking_delta":
                guard let thinking = delta.thinking, !thinking.isEmpty else { return nil }
                return makeChunk(delta: LLMStreamDelta(role: .assistant, reasoning: thinking))
            case "input_json_delta":
                guard let partial = delta.partialJson, !partial.isEmpty,
                      let blockIndex = event.index,
                      let ordinal = toolOrdinalByBlockIndex[blockIndex]
                else { return nil }
                return makeChunk(delta: LLMStreamDelta(
                    role: .assistant,
                    toolCalls: [LLMToolCallDelta(
                        index: ordinal,
                        function: LLMToolCallDeltaFunction(arguments: partial)
                    )]
                ))
            default:
                // signature_delta and future delta kinds carry nothing we map.
                return nil
            }

        case "message_delta":
            let stopReason = event.delta?.stopReason.map(mapAnthropicStopReason) ?? .stop
            let outputTokens = event.usage?.outputTokens
            let usage = LLMTokenUsage(
                promptTokens: inputTokens,
                completionTokens: outputTokens,
                totalTokens: (inputTokens ?? 0) + (outputTokens ?? 0),
                promptTokensDetails: cachedTokens.map { .init(cachedTokens: $0) }
            )
            return makeChunk(
                delta: LLMStreamDelta(role: .assistant),
                finishReason: stopReason.wireValue,
                usage: usage
            )

        default:
            // content_block_stop, message_stop, ping: nothing to map.
            return nil
        }
    }

    private func makeChunk(
        delta: LLMStreamDelta,
        finishReason: String? = nil,
        usage: LLMTokenUsage? = nil
    ) -> LLMStreamChunk {
        LLMStreamChunk(
            id: messageID.isEmpty ? UUID().uuidString : messageID,
            model: model,
            choices: [LLMStreamChoice(index: 0, delta: delta, finishReason: finishReason)],
            usage: usage
        )
    }
}
