import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import struct JSONSchema.Schema
import Logging
import PKShared
import PKUtilities
import Synchronization

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

    private static let defaultBaseURL = URL(string: "https://openrouter.ai/api")!

    /// Decoder for streamed `LLMStreamChunk`s. Uses `.convertFromSnakeCase` because the OpenAI/
    /// OpenRouter SSE wire format is snake_case (`tool_calls`, `finish_reason`, `prompt_tokens`)
    /// while `LLMStreamChunk` and its nested types use camelCase properties with no explicit
    /// CodingKeys. Without this, those fields silently decode to nil (YAK-23).
    private static let streamChunkDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

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
        self.init(
            apiKey: apiKey,
            modelName: modelName,
            baseURL: Self.baseURL(scheme: scheme, host: host, port: port),
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            transport: transport,
            attribution: attribution
        )
    }

    package init(
        apiKey: String,
        modelName: String = "openai/gpt-4o",
        baseURL: URL,
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        attribution: Attribution = .init()
    ) {
        self.init(
            apiKey: apiKey,
            modelName: modelName,
            baseURL: baseURL,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            transport: URLSessionProviderHTTPTransport(timeoutIntervalForRequest: timeoutInterval),
            attribution: attribution
        )
    }

    package init(
        apiKey: String,
        modelName: String = "openai/gpt-4o",
        baseURL: URL,
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
        endpoint = Self.validatedBaseURL(baseURL)
    }

    /// Returns a normalized, validated OpenRouter API base URL while retaining any configured
    /// reverse-proxy path prefix.
    package static func validatedBaseURL(from endpoint: String) -> URL {
        guard let url = URL(string: endpoint) else { return defaultBaseURL }
        return validatedBaseURL(url)
    }

    private static func baseURL(scheme: String, host: String, port: Int) -> URL {
        var urlString = "\(scheme)://\(host)"
        if port != 443, port != 80 { urlString += ":\(port)" }
        if !urlString.contains("/api") { urlString += "/api" }
        return URL(string: urlString) ?? defaultBaseURL
    }

    private static func validatedBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else { return defaultBaseURL }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty {
            path = "/api"
        } else {
            if !path.hasPrefix("/") { path.insert("/", at: path.startIndex) }
            let lastPathComponent = path.split(separator: "/").last.map(String.init)
            if lastPathComponent?.lowercased() != "api" {
                path += "/api"
            }
        }
        components.path = path
        return components.url ?? defaultBaseURL
    }

    /// Exposes the configured attribution for `@testable` verification that the public
    /// `PositronicKit.init(openRouterKey:...)` → `LLMConfiguration` → registry factory path
    /// actually threads `applicationURL`/`applicationTitle` through to a real client (PKR-4).
    var currentAttribution: Attribution {
        attribution
    }

    package var currentBaseURL: URL {
        endpoint
    }

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, responseModalities: [.text], audioOutput: nil)
    }

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let endpoint = self.endpoint
        let apiKey = self.apiKey
        let modelName = self.modelName
        let logger = self.logger
        let maxRetries = self.maxRetries
        let chatURL = endpoint
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")

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
                                messages: messages.map { OpenRouterMessage($0, logger: logger) },
                                model: modelName,
                                frequencyPenalty: generationParameters?.frequencyPenalty,
                                maxCompletionTokens: generationParameters?.maxTokens,
                                presencePenalty: generationParameters?.presencePenalty,
                                responseFormat: self.mapResponseFormat(responseFormat),
                                seed: generationParameters?.seed,
                                temperature: generationParameters?.temperature,
                                toolChoice: self.mapToolChoice(toolChoice, tools: tools),
                                tools: tools?.map(OpenRouterTool.init),
                                topP: generationParameters?.topP,
                                stream: true,
                                streamOptions: .init(includeUsage: true),
                                modalities: responseModalities.contains(.audio) ? [.text, .audio] : nil,
                                audio: audioOutput
                            )
                        )
                        try await self.streamChatResponse(
                            request: request,
                            recoveryState: recoveryState,
                            logger: logger,
                            continuation: continuation,
                            audioFormat: audioOutput?.format
                        )

                        // Summarize what the model returned, so a model that emits no tool call is
                        // distinguishable from a parse/recovery failure when debugging tool calling.
                        let summary = recoveryState.withLock {
                            (finished: $0.finishedWithToolCalls, streamed: $0.sawStreamedToolCalls, yielded: $0.hasYielded)
                        }
                        logger.debug(
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
                                    messages: messages.map { OpenRouterMessage($0, logger: logger) },
                                    model: modelName,
                                    frequencyPenalty: generationParameters?.frequencyPenalty,
                                    maxCompletionTokens: generationParameters?.maxTokens,
                                    presencePenalty: generationParameters?.presencePenalty,
                                    responseFormat: self.mapResponseFormat(responseFormat),
                                    seed: generationParameters?.seed,
                                    temperature: generationParameters?.temperature,
                                    toolChoice: self.mapToolChoice(toolChoice, tools: tools),
                                    tools: tools?.map(OpenRouterTool.init),
                                    topP: generationParameters?.topP,
                                    stream: false,
                                    streamOptions: nil,
                                    modalities: nil,
                                    audio: nil
                                )
                            )
                            let recoveryResult = try await self.fetchChatResponse(request: recoveryRequest)
                            if !Task.isCancelled, let recoveryChunk = self.makeToolCallRecoveryChunk(from: recoveryResult) {
                                logger.debug("OpenRouter tool-call recovery succeeded: \(recoveryChunk.choices.first?.delta.toolCalls?.count ?? 0) tool call(s) recovered")
                                continuation.yield(recoveryChunk)
                            } else {
                                let error = LLMServiceError.unexpectedResponse(
                                    provider: "OpenRouter",
                                    reason: "tool-call recovery returned no usable tool calls"
                                )
                                logger.error("\(error.userFriendlyMessage)")
                                throw error
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try? encoder.encode(query)
        return request
    }

    private func streamChatResponse(
        request: URLRequest,
        recoveryState: borrowing Mutex<LLMToolCallRecoveryState>,
        logger: Logger,
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation,
        audioFormat: AudioFormat? = nil
    ) async throws {
        let (stream, response) = try await transport.lines(for: request)
        let httpResponse = try HTTPHelpers.ensureHTTPResponse(response, provider: "OpenRouter")
        if !(200 ... 299).contains(httpResponse.statusCode) {
            let errorBody = try await LimitedErrorBodyCollector.collect(from: stream)
            try HTTPHelpers.ensureSuccessStatus(httpResponse, provider: "OpenRouter", body: Data(errorBody.utf8))
        }
        for try await line in stream {
            if Task.isCancelled { break }
            processSSELine(
                line,
                recoveryState: recoveryState,
                logger: logger,
                continuation: continuation,
                audioFormat: audioFormat
            )
        }
        // A 2xx stream that yields neither content nor tool calls is abnormal (e.g. a model
        // returning an empty completion). Surface it so it isn't a silent dead end.
        if !recoveryState.withLock(\.hasYielded) {
            logger.warning("OpenRouter stream completed with no content and no tool calls")
        }
    }

    private func fetchChatResponse(request: URLRequest) async throws -> OpenRouterChatResponse {
        let (data, response) = try await transport.data(for: request)
        let httpResponse = try HTTPHelpers.ensureHTTPResponse(response, provider: "OpenRouter")
        try HTTPHelpers.ensureSuccessStatus(httpResponse, provider: "OpenRouter", body: data)
        return try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
    }

    private nonisolated func processSSELine(
        _ line: String,
        recoveryState: borrowing Mutex<LLMToolCallRecoveryState>,
        logger: Logger,
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation,
        audioFormat: AudioFormat? = nil
    ) {
        guard let data = HTTPHelpers.extractSSEData(from: line) else { return }
        let dataString = String(decoding: data, as: UTF8.self)

        do {
            // The wire format is snake_case (`tool_calls`, `finish_reason`) but `LLMStreamChunk`'s
            // properties are camelCase with no explicit CodingKeys. Without convertFromSnakeCase
            // those fields silently decode to nil (they are optional), so every streamed tool call
            // and every finish_reason was being dropped — breaking tool calling for all models
            // via OpenRouter, and defeating the tool-call recovery path (YAK-23). We decode into
            // the provider-specific `OpenRouterStreamChunk` (which also captures `delta.reasoning`
            // for reasoning models — STAB-7) then convert into the transport-neutral
            // `LLMStreamChunk`, mapping `reasoning` → `thinking`.
            let raw = try Self.streamChunkDecoder.decode(OpenRouterStreamChunk.self, from: data)
            let result = raw.toLLMStreamChunk(audioFormat: audioFormat)
            recoveryState.withLock {
                $0.observe(
                    yieldedContent: !(result.choices.first?.delta.content?.isEmpty ?? true),
                    streamedToolCalls: result.choices.first?.delta.toolCalls != nil,
                    finishedWithToolCalls: result.choices.contains(where: { $0.finishReason == "tool_calls" })
                )
            }
            continuation.yield(result)
        } catch {
            logger.error("Failed to decode OpenRouter chunk: \(error.localizedDescription). payloadBytes=\(data.count) payloadHash=\(redactedHash(dataString))")
            continuation.finish(throwing: error)
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
                    content: choice.message.content.text,
                    toolCalls: mappedToolCalls
                ),
                finishReason: FinishReason(wireValue: choice.finishReason).wireValue
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
            let stream = await self.chatStream(
                messages: [LLMMessage(role: .user, content: content)],
                tools: nil,
                toolChoice: nil,
                responseFormat: responseFormat,
                generationParameters: generationParameters
            )
            return try await accumulateStreamContent(from: stream)
        }
    }

    public func fetchAvailableModels() async throws -> [String]? {
        let maxRetries = self.maxRetries
        let endpoint = self.endpoint
        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            let url = endpoint
                .appendingPathComponent("v1")
                .appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.timeoutInterval = self.timeoutInterval
            let (data, response) = try await self.transport.data(for: request)
            let httpResponse = try HTTPHelpers.ensureHTTPResponse(response, provider: "OpenRouter models API")
            try HTTPHelpers.ensureSuccessStatus(httpResponse, provider: "OpenRouter", body: data)
            let modelsResponse = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
            return modelsResponse.data.map { $0.id }.sorted()
        }
    }

    private nonisolated func mapToolChoice(
        _ choice: LLMToolChoice?,
        tools: [LLMToolDefinition]?
    ) -> OpenRouterToolChoice? {
        switch choice {
        case nil:
            // Preserve OpenRouter's existing default: an unspecified choice with tools is auto.
            return tools != nil ? .auto : nil
        case .some(.none): return OpenRouterToolChoice.none
        case .some(.auto): return .auto
        case let .some(.function(name)): return .function(name)
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
