import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import struct JSONSchema.Schema
import Logging
import PKShared
import PositronicKit
import Synchronization

private struct OpenRouterModelsResponse: Codable {
    struct Model: Codable { let id: String }
    let data: [Model]
}

private struct OpenRouterChatResponse: Codable {
    struct Choice: Codable {
        let index: Int
        let message: OpenRouterMessage
        let finishReason: String

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    let id: String
    let model: String
    let choices: [Choice]
    let usage: OpenRouterUsage?
}

private struct OpenRouterUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct OpenRouterChatRequest: Codable {
    let messages: [OpenRouterMessage]
    let model: String
    let frequencyPenalty: Double?
    let maxCompletionTokens: Int?
    let presencePenalty: Double?
    let responseFormat: OpenRouterResponseFormat?
    let seed: Int?
    let temperature: Double?
    let toolChoice: OpenRouterToolChoice?
    let tools: [OpenRouterTool]?
    let topP: Double?
    let stream: Bool
    let streamOptions: OpenRouterStreamOptions?

    enum CodingKeys: String, CodingKey {
        case messages, model, seed, temperature, tools, stream
        case frequencyPenalty = "frequency_penalty"
        case maxCompletionTokens = "max_completion_tokens"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
        case toolChoice = "tool_choice"
        case topP = "top_p"
        case streamOptions = "stream_options"
    }
}

private struct OpenRouterMessage: Codable {
    let role: String
    let content: String
    let name: String?
    let toolCallID: String?
    let toolCalls: [OpenRouterToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    init(_ message: LLMMessage) {
        role = message.role.rawValue
        content = message.content
        name = message.name
        toolCallID = message.toolCallID
        toolCalls = message.toolCalls?.map(OpenRouterToolCall.init)
    }
}

private struct OpenRouterToolCall: Codable {
    let id: String
    let type: String
    let function: OpenRouterToolCallFunction

    init(_ call: LLMToolCall) {
        id = call.id
        type = "function"
        function = .init(name: call.name, arguments: call.arguments)
    }
}

private struct OpenRouterToolCallFunction: Codable {
    let name: String
    let arguments: String
}

private struct OpenRouterTool: Codable {
    let type: String
    let function: OpenRouterToolDefinition

    init(_ tool: LLMToolDefinition) {
        type = "function"
        function = .init(name: tool.name, description: tool.description, parameters: tool.parameters, strict: tool.strict)
    }
}

private struct OpenRouterToolDefinition: Codable {
    let name: String
    let description: String?
    let parameters: Schema?
    let strict: Bool?
}

private enum OpenRouterToolChoice: Codable {
    case auto
    case function(String)

    private struct FunctionWrapper: Codable {
        let type: String
        let function: NamedFunction
    }

    private struct NamedFunction: Codable { let name: String }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto:
            try container.encode("auto")
        case let .function(name):
            try container.encode(FunctionWrapper(type: "function", function: NamedFunction(name: name)))
        }
    }
}

private enum OpenRouterResponseFormat: Codable {
    case jsonObject
    case jsonSchema(OpenRouterResponseSchema)

    private struct KindOnly: Codable { let type: String }

    private struct SchemaWrapper: Codable {
        let type: String
        let jsonSchema: OpenRouterResponseSchema

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .jsonObject:
            try container.encode(KindOnly(type: "json_object"))
        case let .jsonSchema(schema):
            try container.encode(SchemaWrapper(type: "json_schema", jsonSchema: schema))
        }
    }
}

private struct OpenRouterResponseSchema: Codable {
    let name: String
    let description: String?
    let schema: Schema?
    let strict: Bool?
}

private struct OpenRouterStreamOptions: Codable {
    let includeUsage: Bool
    enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
}

public actor OpenRouterClient: LLMClientProtocol {
    public struct Attribution: Sendable, Equatable {
        public let applicationURL: String?
        public let applicationTitle: String?

        public init(applicationURL: String? = nil, applicationTitle: String? = nil) {
            self.applicationURL = applicationURL
            self.applicationTitle = applicationTitle
        }
    }

    private let apiKey: String
    private let modelName: String
    private let endpoint: URL
    private let maxRetries: Int
    private let logger = Logger.module(named: "openrouter-client")
    private let timeoutInterval: TimeInterval
    private let transport: any ProviderHTTPTransport
    private let attribution: Attribution

    public init(
        apiKey: String,
        modelName: String = "openai/gpt-4o",
        host: String = "openrouter.ai",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        attribution: Attribution = .init()
    ) {
        self.init(
            apiKey: apiKey,
            modelName: modelName,
            host: host,
            port: port,
            scheme: scheme,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            transport: URLSessionProviderHTTPTransport(timeoutIntervalForRequest: timeoutInterval),
            attribution: attribution
        )
    }

    package init(
        apiKey: String,
        modelName: String = "openai/gpt-4o",
        host: String = "openrouter.ai",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        transport: any ProviderHTTPTransport,
        attribution: Attribution = .init()
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
        self.transport = transport
        self.attribution = attribution

        var urlString = "\(scheme)://\(host)"
        if port != 443, port != 80 { urlString += ":\(port)" }
        if !urlString.contains("/api") { urlString += "/api" }
        endpoint = URL(string: urlString) ?? URL(string: "https://openrouter.ai/api")!
    }

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let endpoint = self.endpoint
        let apiKey = self.apiKey
        let modelName = self.modelName
        let logger = self.logger
        let maxRetries = self.maxRetries
        let chatURL = endpoint.appendingPathComponent("v1/chat/completions")

        return CancellableAsyncThrowingStream.make(of: LLMStreamChunk.self) { continuation in
            let recoveryState = Mutex(LLMToolCallRecoveryState())

            do {
                try await RetryPolicy.retry(
                    maxRetries: maxRetries,
                    shouldRetry: { error in
                        recoveryState.withLock { $0.shouldRetryAfterError } && RetryPolicy.isTransient(error: error)
                    },
                    operation: {
                        let request = self.buildChatRequest(
                            chatURL: chatURL,
                            apiKey: apiKey,
                            timeoutInterval: self.timeoutInterval,
                            attribution: self.attribution,
                            query: OpenRouterChatRequest(
                                messages: messages.map(OpenRouterMessage.init),
                                model: modelName,
                                frequencyPenalty: generationParameters?.frequencyPenalty,
                                maxCompletionTokens: generationParameters?.maxTokens,
                                presencePenalty: generationParameters?.presencePenalty,
                                responseFormat: self.mapResponseFormat(responseFormat),
                                seed: generationParameters?.seed,
                                temperature: generationParameters?.temperature,
                                toolChoice: self.mapToolChoice(toolChoice ?? (tools != nil ? .auto : nil)),
                                tools: tools?.map(OpenRouterTool.init),
                                topP: generationParameters?.topP,
                                stream: true,
                                streamOptions: .init(includeUsage: true)
                            )
                        )
                        try await self.streamChatResponse(
                            request: request,
                            recoveryState: recoveryState,
                            logger: logger,
                            continuation: continuation
                        )

                        // Diagnostic (YAK-23): summarize what the model actually returned so a model
                        // that emits no tool call is distinguishable from a parse/recovery failure.
                        let summary = recoveryState.withLock {
                            (finished: $0.finishedWithToolCalls, streamed: $0.sawStreamedToolCalls, yielded: $0.hasYielded)
                        }
                        logger.info(
                            "OpenRouter stream complete (model \(modelName)): finishedWithToolCalls=\(summary.finished) sawStreamedToolCalls=\(summary.streamed) yieldedAnything=\(summary.yielded) toolsAdvertised=\(tools?.count ?? 0)"
                        )

                        if !Task.isCancelled, recoveryState.withLock(\.shouldRecoverToolCalls) {
                            logger.warning("OpenRouter stream finished with tool_calls but no streamed delta.toolCalls were received. Recovering tool calls from non-stream response.")
                            let recoveryRequest = self.buildChatRequest(
                                chatURL: chatURL,
                                apiKey: apiKey,
                                timeoutInterval: self.timeoutInterval,
                                attribution: self.attribution,
                                query: OpenRouterChatRequest(
                                    messages: messages.map(OpenRouterMessage.init),
                                    model: modelName,
                                    frequencyPenalty: generationParameters?.frequencyPenalty,
                                    maxCompletionTokens: generationParameters?.maxTokens,
                                    presencePenalty: generationParameters?.presencePenalty,
                                    responseFormat: self.mapResponseFormat(responseFormat),
                                    seed: generationParameters?.seed,
                                    temperature: generationParameters?.temperature,
                                    toolChoice: self.mapToolChoice(toolChoice ?? (tools != nil ? .auto : nil)),
                                    tools: tools?.map(OpenRouterTool.init),
                                    topP: generationParameters?.topP,
                                    stream: false,
                                    streamOptions: nil
                                )
                            )
                            let recoveryResult = try await self.fetchChatResponse(request: recoveryRequest)
                            if !Task.isCancelled, let recoveryChunk = self.makeToolCallRecoveryChunk(from: recoveryResult) {
                                logger.info("OpenRouter tool-call recovery succeeded: \(recoveryChunk.choices.first?.delta.toolCalls?.count ?? 0) tool call(s) recovered")
                                continuation.yield(recoveryChunk)
                            } else {
                                logger.warning("OpenRouter tool-call recovery produced no usable tool calls (non-stream response had finishReason!=tool_calls or empty tool_calls)")
                            }
                        }
                    }
                )
                continuation.finish()
            } catch {
                logger.error("OpenRouter stream error: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        }
    }

    private nonisolated func buildChatRequest(
        chatURL: URL,
        apiKey: String,
        timeoutInterval: TimeInterval,
        attribution: Attribution,
        query: OpenRouterChatRequest
    ) -> URLRequest {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let applicationURL = attribution.applicationURL {
            request.setValue(applicationURL, forHTTPHeaderField: "HTTP-Referer")
        }
        if let applicationTitle = attribution.applicationTitle {
            request.setValue(applicationTitle, forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try? JSONEncoder().encode(query)
        return request
    }

    private func streamChatResponse(
        request: URLRequest,
        recoveryState: borrowing Mutex<LLMToolCallRecoveryState>,
        logger: Logger,
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) async throws {
        let (stream, response) = try await transport.lines(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.networkError("Invalid response type from OpenRouter")
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = try await LimitedErrorBodyCollector.collect(from: stream)
            throw ProviderHTTPFailure.makeError(
                provider: "OpenRouter",
                response: httpResponse,
                responseBody: errorBody
            )
        }
        for try await line in stream {
            if Task.isCancelled { break }
            processSSELine(
                line,
                recoveryState: recoveryState,
                logger: logger,
                continuation: continuation
            )
        }
    }

    private func fetchChatResponse(request: URLRequest) async throws -> OpenRouterChatResponse {
        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.networkError("Invalid response type from OpenRouter")
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = ProviderHTTPFailure.sanitize(String(data: data, encoding: .utf8) ?? "")
            throw ProviderHTTPFailure.makeError(
                provider: "OpenRouter",
                response: httpResponse,
                responseBody: body
            )
        }
        return try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
    }

    private nonisolated func processSSELine(
        _ line: String,
        recoveryState: borrowing Mutex<LLMToolCallRecoveryState>,
        logger: Logger,
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.hasPrefix("data: ") else { return }
        let dataString = String(trimmed.dropFirst(6))
        guard dataString != "[DONE]", let data = dataString.data(using: .utf8) else { return }

        do {
            let result = try JSONDecoder().decode(LLMStreamChunk.self, from: data)
            recoveryState.withLock {
                $0.observe(
                    yieldedContent: !(result.choices.first?.delta.content?.isEmpty ?? true),
                    streamedToolCalls: result.choices.first?.delta.toolCalls != nil,
                    finishedWithToolCalls: result.choices.contains(where: { $0.finishReason == "tool_calls" })
                )
            }
            continuation.yield(result)
        } catch {
            logger.error("Failed to decode OpenRouter chunk: \(error.localizedDescription). Raw: \(dataString)")
        }
    }

    nonisolated func makeToolCallRecoveryChunk(from responseData: Data) throws -> LLMStreamChunk? {
        let response = try JSONDecoder().decode(OpenRouterChatResponse.self, from: responseData)
        return makeToolCallRecoveryChunk(from: response)
    }

    private nonisolated func makeToolCallRecoveryChunk(from response: OpenRouterChatResponse) -> LLMStreamChunk? {
        guard let choice = response.choices.first else { return nil }
        guard choice.finishReason == "tool_calls" else { return nil }
        guard let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty else { return nil }

        let mappedToolCalls = toolCalls.enumerated().map { index, call in
            LLMToolCallDelta(
                index: index,
                id: call.id,
                function: LLMToolCallDeltaFunction(
                    name: call.function.name,
                    arguments: call.function.arguments
                )
            )
        }

        return LLMStreamChunk(
            id: response.id,
            model: response.model,
            choices: [LLMStreamChoice(
                index: choice.index,
                delta: LLMStreamDelta(
                    role: .assistant,
                    content: choice.message.content,
                    toolCalls: mappedToolCalls
                ),
                finishReason: choice.finishReason
            )],
            usage: response.usage.map {
                LLMTokenUsage(
                    promptTokens: $0.promptTokens,
                    completionTokens: $0.completionTokens,
                    totalTokens: $0.totalTokens
                )
            }
        )
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
                if let delta = result.choices.first?.delta.content { fullContent += delta }
            }
            return fullContent
        }
    }

    public func fetchAvailableModels() async throws -> [String]? {
        let maxRetries = self.maxRetries
        let endpoint = self.endpoint
        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            let url = endpoint.appendingPathComponent("v1/models")
            var request = URLRequest(url: url)
            request.timeoutInterval = self.timeoutInterval
            let (data, response) = try await self.transport.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMServiceError.networkError("Invalid response type from OpenRouter models API")
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw ProviderHTTPFailure.makeError(
                    provider: "OpenRouter",
                    response: httpResponse,
                    responseBody: ProviderHTTPFailure.sanitize(String(data: data, encoding: .utf8) ?? "")
                )
            }
            let modelsResponse = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
            return modelsResponse.data.map { $0.id }.sorted()
        }
    }

    private nonisolated func mapToolChoice(_ choice: LLMToolChoice?) -> OpenRouterToolChoice? {
        switch choice {
        case .none: return nil
        case .auto: return .auto
        case let .function(name): return .function(name)
        }
    }

    private nonisolated func mapResponseFormat(_ format: LLMResponseFormat?) -> OpenRouterResponseFormat? {
        switch format {
        case .none, .text:
            return nil
        case .jsonObject:
            return .jsonObject
        case let .jsonSchema(schema):
            return .jsonSchema(.init(
                name: schema.name,
                description: schema.description,
                schema: schema.schema,
                strict: schema.strict
            ))
        }
    }
}
