import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import PKContracts
import PKUtilities
import Synchronization

/// Which OpenAI HTTP API an ``OpenAIClient`` speaks.
public enum OpenAIAPI: Sendable, Equatable {
    /// Responses for `api.openai.com`, Chat Completions elsewhere. Audio output forces Chat Completions.
    case automatic
    case chatCompletions
    case responses
}

/// `LLMClientProtocol` adapter over OpenAI Chat Completions and Responses APIs.
///
/// Stateless: the runtime owns history (Timeline is the source of truth), so
/// `previous_response_id` is never used; each round sends the full `input` with `store: false`.
/// Reasoning continuity uses `include: ["reasoning.encrypted_content"]` with encrypted items
/// replayed from the provider continuation reference on the assistant message.
public actor OpenAIClient: LLMClientProtocol {
    public let structuredOutputAdapter: any StructuredOutputAdapter
    /// OpenAI caches prefixes automatically; the adapter only supplies a routing key and, for
    /// supported models, a retention window (#279).
    public nonisolated var promptCachingCapability: PromptCachingCapability {
        .automatic
    }
    private let apiKey: String
    private let modelName: String
    private let host: String
    private let port: Int
    private let scheme: String
    private let timeoutInterval: TimeInterval
    private let maxRetries: Int
    private let api: OpenAIAPI
    private let transport: any ProviderHTTPTransport
    private let logger = Logger.module(named: "openai-client")

    public init(
        apiKey: String,
        modelName: String = "gpt-4o",
        host: String = "api.openai.com",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        structuredOutputAdapter: any StructuredOutputAdapter = NativeJSONSchemaStructuredOutputAdapter(),
        api: OpenAIAPI = .automatic
    ) {
        self.init(apiKey: apiKey, modelName: modelName, host: host, port: port, scheme: scheme, timeoutInterval: timeoutInterval, maxRetries: maxRetries, transport: URLSessionProviderHTTPTransport(timeoutIntervalForRequest: timeoutInterval), structuredOutputAdapter: structuredOutputAdapter, api: api)
    }

    package init(
        apiKey: String, modelName: String = "gpt-4o", host: String = "api.openai.com",
        port: Int = 443, scheme: String = "https", timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3, transport: any ProviderHTTPTransport,
        structuredOutputAdapter: any StructuredOutputAdapter = NativeJSONSchemaStructuredOutputAdapter(),
        api: OpenAIAPI = .automatic
    ) {
        self.apiKey = apiKey; self.modelName = modelName; self.host = host
        self.port = port; self.scheme = scheme; self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries; self.transport = transport
        self.structuredOutputAdapter = structuredOutputAdapter; self.api = api
    }

    package nonisolated func resolvedAPI(hasAudioOutput: Bool) -> OpenAIAPI {
        switch api {
        case .chatCompletions: return .chatCompletions
        case .responses: return hasAudioOutput ? .chatCompletions : .responses
        case .automatic:
            if hasAudioOutput { return .chatCompletions }
            return host.lowercased() == "api.openai.com" ? .responses : .chatCompletions
        }
    }

    private nonisolated var baseURL: URL {
        var components = URLComponents()
        components.scheme = scheme; components.host = host
        if !((scheme == "https" && port == 443) || (scheme == "http" && port == 80) || port == 0) { components.port = port }
        return components.url ?? URL(string: "https://api.openai.com")!
    }

    public func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: [.text], audioOutput: nil, promptCache: nil)
    }

    public func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: audioOutput, promptCache: nil)
    }

    public func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?, promptCache: PromptCacheDirective?) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let maxRetries = self.maxRetries
        return CancellableAsyncThrowingStream.make(of: LLMStreamChunk.self) { continuation in
            do {
                try validateLLMMessageHistory(messages)
                if self.resolvedAPI(hasAudioOutput: audioOutput != nil) == .responses {
                    try await self.streamResponses(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, promptCache: promptCache, maxRetries: maxRetries, continuation: continuation)
                } else {
                    try await self.streamChatCompletions(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: audioOutput, promptCache: promptCache, maxRetries: maxRetries, continuation: continuation)
                }
                continuation.finish()
            } catch {
                self.logger.error("OpenAI stream error: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: - Chat Completions path (shared wire)

    package nonisolated func makeChatRequest(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?, promptCache: PromptCacheDirective? = nil, stream: Bool) throws -> URLRequest {
        let query = ChatCompletionsChatRequest(
            messages: messages.map { ChatCompletionsMessage($0, provider: .openAI) },
            model: modelName,
            frequencyPenalty: generationParameters?.frequencyPenalty,
            maxCompletionTokens: generationParameters?.maxTokens,
            presencePenalty: generationParameters?.presencePenalty,
            responseFormat: ChatCompletionsWire.mapResponseFormat(responseFormat),
            seed: generationParameters?.seed,
            temperature: generationParameters?.temperature,
            toolChoice: ChatCompletionsWire.mapToolChoice(toolChoice, tools: tools),
            tools: tools?.map(ChatCompletionsTool.init),
            topP: generationParameters?.topP,
            stream: stream,
            streamOptions: stream ? .init(includeUsage: true) : nil,
            modalities: responseModalities.contains(.audio) ? [.text, .audio] : nil,
            audio: audioOutput,
            promptCacheKey: promptCache?.routingKey,
            promptCacheRetention: OpenAIPromptCache.retention(for: promptCache, model: modelName)
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ChatCompletionsWire.sortedEncoder().encode(query)
        return request
    }

    private func streamChatCompletions(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?, promptCache: PromptCacheDirective?, maxRetries: Int, continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation) async throws {
        let request = try makeChatRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: audioOutput, promptCache: promptCache, stream: true)
        let recoveryState = Mutex(LLMToolCallRecoveryState())
        let decoder = ChatCompletionsWire.streamChunkDecoder
        try await RetryPolicy.retry(maxRetries: maxRetries, shouldRetry: { recoveryState.withLock { $0.shouldRetryAfterError } && RetryPolicy.isTransient(error: $0) }) {
            let stream = try await HTTPHelpers.openLineStream(request, transport: self.transport, provider: "OpenAI")
            for try await line in stream {
                if Task.isCancelled { break }
                guard let data = HTTPHelpers.extractSSEData(from: line) else { continue }
                do {
                    let raw = try decoder.decode(ChatCompletionsStreamChunk.self, from: data)
                    let chunk = raw.toLLMStreamChunk(audioFormat: audioOutput?.format, continuationProvider: .openAI)
                    recoveryState.withLock { $0.observe(yieldedContent: chunk.carriesConsumerOutput, streamedToolCalls: chunk.choices.first?.delta.toolCalls != nil, finishedWithToolCalls: chunk.choices.contains(where: { $0.finishReason == "tool_calls" })) }
                    continuation.yield(chunk)
                } catch {
                    self.logger.error("Failed to decode OpenAI chunk: \(error.localizedDescription)")
                    throw error
                }
            }
            if !Task.isCancelled, recoveryState.withLock(\.shouldRecoverToolCalls) {
                let recoveryRequest = try self.makeChatRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: nil, promptCache: promptCache, stream: false)
                let response: ChatCompletionsChatResponse = try await HTTPHelpers.fetchDecodable(ChatCompletionsChatResponse.self, for: recoveryRequest, transport: self.transport, provider: "OpenAI")
                if let chunk = self.makeToolCallRecoveryChunk(from: response) { continuation.yield(chunk) }
            }
        }
    }

    package nonisolated func makeToolCallRecoveryChunk(from response: ChatCompletionsChatResponse) -> LLMStreamChunk? {
        guard let choice = response.choices.first, choice.finishReason == "tool_calls",
              let calls = choice.message.toolCalls, !calls.isEmpty else { return nil }
        let chunk = response.toLLMStreamChunk(continuationProvider: .openAI)
        return LLMStreamChunk(id: chunk.id, model: chunk.model, choices: Array(chunk.choices.prefix(1)), usage: chunk.usage)
    }

    public func chatCompletion(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality> = [.text], audioOutput: AudioOutputOptions? = nil) async throws -> LLMStreamChunk {
        try await chatCompletion(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: audioOutput, promptCache: nil)
    }

    public func chatCompletion(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?, promptCache: PromptCacheDirective?) async throws -> LLMStreamChunk {
        try validateLLMMessageHistory(messages)
        if resolvedAPI(hasAudioOutput: audioOutput != nil) == .responses {
            return try await fetchResponses(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, promptCache: promptCache)
        }
        let request = try makeChatRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: audioOutput, promptCache: promptCache, stream: false)
        let response: ChatCompletionsChatResponse = try await RetryPolicy.retry(maxRetries: maxRetries) {
            try await HTTPHelpers.fetchDecodable(ChatCompletionsChatResponse.self, for: request, transport: self.transport, provider: "OpenAI")
        }
        return response.toLLMStreamChunk(audioFormat: audioOutput?.format, continuationProvider: .openAI)
    }

    // MARK: - Responses path

    package nonisolated func makeResponsesRequest(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, promptCache: PromptCacheDirective? = nil, stream: Bool) throws -> URLRequest {
        var input: [ResponsesInputItem] = []
        for m in messages {
            switch m.role {
            case .tool:
                input.append(.functionCallOutput(callId: m.toolCallID ?? "", output: m.content))
            case .assistant:
                fallthrough
            default:
                var parts: [ResponsesContentPart] = []
                if m.messageContent.isTextOnly {
                    if !m.content.isEmpty { parts.append(.text(m.content)) }
                } else {
                    for part in m.messageContent.parts {
                        switch part {
                        case let .text(t): parts.append(.text(t))
                        case let .image(img): parts.append(.image(data: img.data, mediaType: img.mediaType, detail: img.detail.map { $0 == .automatic ? "auto" : $0.rawValue }))
                        case let .audio(a): parts.append(.audio(data: a.data, format: a.format.rawValue))
                        }
                    }
                }
                let calls = m.role == .assistant ? m.toolCalls ?? [] : []
                if !parts.isEmpty || calls.isEmpty {
                    input.append(.message(role: m.role.rawValue, content: parts))
                }
                for call in calls {
                    input.append(.functionCall(callId: call.id, name: call.name, arguments: call.arguments))
                }
            }
        }
        let textFormat: ResponsesTextFormat? = switch responseFormat {
        case .none, .text: nil
        case .jsonObject: .jsonObject
        case let .jsonSchema(s): .jsonSchema(name: s.name, description: s.description, schema: s.schema, strict: s.isStrict)
        }
        let body = ResponsesRequest(
            model: modelName, input: input,
            tools: tools?.map { ResponsesTool(name: $0.name, description: $0.description, parameters: $0.parameters, strict: $0.isStrict) },
            toolChoice: mapResponsesToolChoice(toolChoice, tools: tools),
            text: textFormat.map { ResponsesTextConfig(format: $0) },
            reasoning: ResponsesReasoningConfig(effort: nil, summary: "auto"),
            include: ["reasoning.encrypted_content"], store: false, stream: stream,
            maxOutputTokens: generationParameters?.maxTokens, temperature: generationParameters?.temperature,
            topP: generationParameters?.topP, seed: generationParameters?.seed,
            presencePenalty: generationParameters?.presencePenalty, frequencyPenalty: generationParameters?.frequencyPenalty,
            promptCacheKey: promptCache?.routingKey,
            promptCacheRetention: OpenAIPromptCache.retention(for: promptCache, model: modelName)
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/responses"))
        request.httpMethod = "POST"; request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }

    private nonisolated func mapResponsesToolChoice(_ choice: LLMToolChoice?, tools: [LLMToolDefinition]?) -> ResponsesToolChoice? {
        switch choice {
        case nil: return tools != nil ? .auto : nil
        case .some(.none): return ResponsesToolChoice.none
        case .some(.auto): return ResponsesToolChoice.auto
        case let .some(.function(name)): return .function(name)
        }
    }

    private func streamResponses(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, promptCache: PromptCacheDirective?, maxRetries: Int, continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation) async throws {
        let request = try makeResponsesRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, promptCache: promptCache, stream: true)
        let accumulator = Mutex(ResponsesStreamAccumulator())
        try await RetryPolicy.retry(maxRetries: maxRetries, shouldRetry: { _ in false }) {
            let stream = try await HTTPHelpers.openLineStream(request, transport: self.transport, provider: "OpenAI")
            for try await line in stream {
                if Task.isCancelled { break }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if trimmed.hasPrefix("event:") {
                    continue
                }
                guard let data = HTTPHelpers.extractSSEData(from: line) else {
                    continue
                }
                let payloadJSON = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let eventType = (payloadJSON["type"] as? String) ?? ""
                let terminal = ResponsesEvents.terminalEvent(forEventType: eventType, payload: data)
                let chunk = accumulator.withLock { state in
                    ResponsesEvents.chunk(forEventType: eventType, payload: data, model: self.modelName, responseID: (payloadJSON["response_id"] as? String) ?? (payloadJSON["id"] as? String) ?? "", accumulator: &state)
                }
                if let chunk {
                    continuation.yield(chunk)
                }
                if let terminal {
                    accumulator.withLock { $0.sawTerminalEvent = true }
                    switch terminal {
                    case .completed, .incomplete:
                        // Valid terminal: the terminal chunk already carried `finishReason`
                        // (`stop` or the mapped incomplete reason) and usage.
                        break
                    case let .failed(message), let .providerError(message):
                        // Provider-reported failure after the event loop: throw so the stream
                        // finishes with an error instead of a clean successful EOF. Chunks
                        // yielded before the failure remain delivered (partial-output contract).
                        throw LLMServiceError.unexpectedResponse(provider: "OpenAI", reason: "provider reported failure: \(message)")
                    }
                }
            }
            // Abnormal EOF (issue #369): the protocol requires exactly one terminal event
            // (`response.completed`, `response.incomplete`, `response.failed`, `error`). A
            // stream that ends without one (connection dropped, truncated SSE body) must not
            // be mistaken for success; throw so the Turn ends failed with the partial output
            // preserved. Cancellation by the consumer is not a protocol violation.
            guard accumulator.withLock(\.sawTerminalEvent) || Task.isCancelled else {
                throw LLMServiceError.unexpectedResponse(provider: "OpenAI", reason: "stream ended before a terminal response event")
            }
        }
    }

    private func fetchResponses(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, promptCache: PromptCacheDirective?) async throws -> LLMStreamChunk {
        struct CompletedResponse: Decodable {
            struct ContentPart: Decodable {
                let type: String
                let text: String?
                let refusal: String?
            }
            struct OutputItem: Decodable {
                let type: String
                let text: String?
                let content: [ContentPart]?
                let status: String?
                let name: String?
                let arguments: String?
                let callId: String?
                let id: String?
                enum CodingKeys: String, CodingKey { case type, text, content, status, name, arguments; case callId = "call_id"; case id }
            }
            struct IncompleteDetails: Decodable {
                let reason: String?
            }
            struct Usage: Decodable {
                struct InputTokensDetails: Decodable {
                    let cachedTokens: Int?
                    let cacheWriteTokens: Int?
                    enum CodingKeys: String, CodingKey {
                        case cachedTokens = "cached_tokens"
                        case cacheWriteTokens = "cache_write_tokens"
                    }
                }
                let inputTokens: Int?
                let outputTokens: Int?
                let totalTokens: Int?
                let cacheWriteTokens: Int?
                let inputTokensDetails: InputTokensDetails?
                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case outputTokens = "output_tokens"
                    case totalTokens = "total_tokens"
                    case cacheWriteTokens = "cache_write_tokens"
                    case inputTokensDetails = "input_tokens_details"
                }
            }
            let id: String
            let model: String?
            let output: [OutputItem]?
            let status: String?
            let incompleteDetails: IncompleteDetails?
            let usage: Usage?
            enum CodingKeys: String, CodingKey {
                case id, model, output, status, usage
                case incompleteDetails = "incomplete_details"
            }
        }
        let request = try makeResponsesRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, promptCache: promptCache, stream: false)
        let decoded: CompletedResponse = try await RetryPolicy.retry(maxRetries: maxRetries) {
            try await HTTPHelpers.fetchDecodable(CompletedResponse.self, for: request, transport: self.transport, provider: "OpenAI")
        }
        var text = ""
        var toolDeltas: [LLMToolCallDelta] = []
        for (i, item) in (decoded.output ?? []).enumerated() {
            switch item.type {
            case "message":
                for part in item.content ?? [] {
                    switch part.type {
                    case "output_text": text += part.text ?? ""
                    case "refusal": text += part.refusal ?? ""
                    default: break
                    }
                }
                // Keep accepting the earlier flat shape while decoding the real nested form.
                if item.content == nil { text += item.text ?? "" }
            case "output_text": text += item.text ?? ""
            case "function_call": toolDeltas.append(.init(index: i, id: item.callId ?? item.id, function: .init(name: item.name, arguments: item.arguments)))
            default: break
            }
        }
        let responseStatus = decoded.status ?? decoded.output?.compactMap(\.status).first
        let finishReason: String = switch responseStatus {
        case nil, "completed": FinishReason.stop.wireValue
        case "incomplete":
            switch decoded.incompleteDetails?.reason {
            case "max_output_tokens": FinishReason.length.wireValue
            case "content_filter": FinishReason.contentFilter.wireValue
            case let reason?: FinishReason.other(reason).wireValue
            case nil: FinishReason.other("incomplete").wireValue
            }
        case let status?: FinishReason.other(status).wireValue
        }
        return LLMStreamChunk(id: decoded.id, model: decoded.model ?? modelName, choices: [.init(index: 0, delta: .init(role: .assistant, content: text.isEmpty ? nil : text, toolCalls: toolDeltas.isEmpty ? nil : toolDeltas), finishReason: finishReason)], usage: decoded.usage.map {
            let writeTokens = $0.cacheWriteTokens ?? $0.inputTokensDetails?.cacheWriteTokens
            let details: LLMTokenUsagePromptDetails? = ($0.inputTokensDetails?.cachedTokens != nil || writeTokens != nil)
                ? .init(cachedTokens: $0.inputTokensDetails?.cachedTokens, cacheWriteTokens: writeTokens)
                : nil
            return LLMTokenUsage(promptTokens: $0.inputTokens, completionTokens: $0.outputTokens, totalTokens: $0.totalTokens, promptTokensDetails: details)
        })
    }

    public func sendMessage(_ content: String, responseFormat: LLMResponseFormat? = nil, generationParameters: GenerationParameters? = nil) async throws -> String {
        let stream = await self.chatStream(messages: [LLMMessage(role: .user, content: content)], tools: nil, toolChoice: nil, responseFormat: responseFormat, generationParameters: generationParameters)
        return try await accumulateStreamContent(from: stream)
    }

    public func fetchAvailableModels() async throws -> [String]? {
        var modelsRequest = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        modelsRequest.timeoutInterval = timeoutInterval
        modelsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let request = modelsRequest
        struct ModelsResponse: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            try await HTTPHelpers.fetchDecodable(ModelsResponse.self, for: request, transport: self.transport, provider: "OpenAI").data.map(\.id)
        }
    }
}
