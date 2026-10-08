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

    package func resolvedAPI(hasAudioOutput: Bool) -> OpenAIAPI {
        switch api {
        case .chatCompletions: return .chatCompletions
        case .responses: return hasAudioOutput ? .chatCompletions : .responses
        case .automatic:
            if hasAudioOutput { return .chatCompletions }
            return host.lowercased() == "api.openai.com" ? .responses : .chatCompletions
        }
    }

    private var baseURL: URL {
        var components = URLComponents()
        components.scheme = scheme; components.host = host
        if !((scheme == "https" && port == 443) || (scheme == "http" && port == 80) || port == 0) { components.port = port }
        return components.url ?? URL(string: "https://api.openai.com")!
    }

    public func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: [.text], audioOutput: nil)
    }

    public func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let maxRetries = self.maxRetries
        return CancellableAsyncThrowingStream.make(of: LLMStreamChunk.self) { continuation in
            do {
                try validateLLMMessageHistory(messages)
                if self.resolvedAPI(hasAudioOutput: audioOutput != nil) == .responses {
                    try await self.streamResponses(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, maxRetries: maxRetries, continuation: continuation)
                } else {
                    try await self.streamChatCompletions(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: audioOutput, maxRetries: maxRetries, continuation: continuation)
                }
                continuation.finish()
            } catch {
                self.logger.error("OpenAI stream error: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: - Chat Completions path (shared wire)

    package func makeChatRequest(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?, stream: Bool) throws -> URLRequest {
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
            audio: audioOutput
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = timeoutInterval
        modelsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ChatCompletionsWire.sortedEncoder().encode(query)
        return request
    }

    private func streamChatCompletions(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?, maxRetries: Int, continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation) async throws {
        let request = try makeChatRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: audioOutput, stream: true)
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
                let recoveryRequest = try self.makeChatRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: nil, stream: false)
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
        try validateLLMMessageHistory(messages)
        if resolvedAPI(hasAudioOutput: audioOutput != nil) == .responses {
            return try await fetchResponses(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters)
        }
        let request = try makeChatRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: responseModalities, audioOutput: audioOutput, stream: false)
        let response: ChatCompletionsChatResponse = try await RetryPolicy.retry(maxRetries: maxRetries) {
            try await HTTPHelpers.fetchDecodable(ChatCompletionsChatResponse.self, for: request, transport: self.transport, provider: "OpenAI")
        }
        return response.toLLMStreamChunk(audioFormat: audioOutput?.format, continuationProvider: .openAI)
    }

    // MARK: - Responses path

    package func makeResponsesRequest(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, stream: Bool) throws -> URLRequest {
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
                if let calls = m.toolCalls, !calls.isEmpty, parts.isEmpty { parts.append(.text("")) }
                input.append(.message(role: m.role.rawValue, content: parts))
            }
        }
        let textFormat: ResponsesTextFormat? = switch responseFormat {
        case .none, .text, nil: nil
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
            presencePenalty: generationParameters?.presencePenalty, frequencyPenalty: generationParameters?.frequencyPenalty
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/responses"))
        request.httpMethod = "POST"; request.timeoutInterval = timeoutInterval
        modelsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func mapResponsesToolChoice(_ choice: LLMToolChoice?, tools: [LLMToolDefinition]?) -> ResponsesToolChoice? {
        switch choice {
        case nil: return tools != nil ? .auto : nil
        case .some(.none): return ResponsesToolChoice.none
        case .some(.auto): return ResponsesToolChoice.auto
        case let .some(.function(name)): return .function(name)
        }
    }

    private func streamResponses(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, maxRetries: Int, continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation) async throws {
        let request = try makeResponsesRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, stream: true)
        var accumulator = ResponsesStreamAccumulator()
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
                let eventType = payloadJSON["type"] as? String ?? ""
                if let chunk = ResponsesEvents.chunk(forEventType: eventType, payload: data, model: self.modelName, responseID: (payloadJSON["response_id"] as? String) ?? (payloadJSON["id"] as? String) ?? "", accumulator: &accumulator) {
                    continuation.yield(chunk)
                }
            }
        }
    }

    private func fetchResponses(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?) async throws -> LLMStreamChunk {
        struct CompletedResponse: Decodable {
            struct OutputItem: Decodable {
                let type: String
                let text: String?
                let name: String?
                let arguments: String?
                let callId: String?
                let id: String?
                enum CodingKeys: String, CodingKey { case type, text, name, arguments; case callId = "call_id"; case id }
            }
            struct Usage: Decodable {
                let inputTokens: Int?
                let outputTokens: Int?
                let totalTokens: Int?
                enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens"; case outputTokens = "output_tokens"; case totalTokens = "total_tokens" }
            }
            let id: String
            let model: String?
            let output: [OutputItem]?
            let usage: Usage?
        }
        let request = try makeResponsesRequest(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, stream: false)
        let decoded: CompletedResponse = try await RetryPolicy.retry(maxRetries: maxRetries) {
            try await HTTPHelpers.fetchDecodable(CompletedResponse.self, for: request, transport: self.transport, provider: "OpenAI")
        }
        var text = ""
        var toolDeltas: [LLMToolCallDelta] = []
        for (i, item) in (decoded.output ?? []).enumerated() {
            switch item.type {
            case "message", "output_text": text += item.text ?? ""
            case "function_call": toolDeltas.append(.init(index: i, id: item.callId ?? item.id, function: .init(name: item.name, arguments: item.arguments)))
            default: break
            }
        }
        return LLMStreamChunk(id: decoded.id, model: decoded.model ?? modelName, choices: [.init(index: 0, delta: .init(role: .assistant, content: text.isEmpty ? nil : text, toolCalls: toolDeltas.isEmpty ? nil : toolDeltas), finishReason: FinishReason.stop.wireValue)], usage: decoded.usage.map { LLMTokenUsage(promptTokens: $0.inputTokens, completionTokens: $0.outputTokens, totalTokens: $0.totalTokens) })
    }

    public func sendMessage(_ content: String, responseFormat: LLMResponseFormat? = nil, generationParameters: GenerationParameters? = nil) async throws -> String {
        let stream = await self.chatStream(messages: [LLMMessage(role: .user, content: content)], tools: nil, toolChoice: nil, responseFormat: responseFormat, generationParameters: generationParameters)
        return try await accumulateStreamContent(from: stream)
    }

    public func fetchAvailableModels() async throws -> [String]? {
        var modelsRequest = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        modelsRequest.timeoutInterval = timeoutInterval
        modelsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        struct ModelsResponse: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            try await HTTPHelpers.fetchDecodable(ModelsResponse.self, for: modelsRequest, transport: self.transport, provider: "OpenAI").data.map(\.id)
        }
    }
}
