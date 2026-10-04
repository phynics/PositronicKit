import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import OpenAI
import PKContracts
import PKUtilities
import Synchronization

/// Captures the HTTP status of a single OpenAI SDK response so the native completion path can
/// map non-2xx responses to `LLMServiceError.httpError`.
///
/// The pinned OpenAI SDK validates HTTP status only for streaming requests. Its non-streaming
/// decoder parses an error body as a `ChatResult` and surfaces a `DecodingError`, which carries
/// no status. One instance handles one native completion call, so a concurrent streaming request
/// cannot overwrite the captured status.
private final class OpenAIHTTPStatusCaptureMiddleware: OpenAIMiddleware, Sendable {
    private let statusCode = Mutex<Int?>(nil)

    func intercept(
        response: URLResponse?,
        request: URLRequest,
        data: Data?
    ) -> (response: URLResponse?, data: Data?) {
        if let httpResponse = response as? HTTPURLResponse {
            statusCode.withLock { $0 = httpResponse.statusCode }
        }
        return (response, data)
    }

    func capturedStatusCode() -> Int? {
        statusCode.withLock { $0 }
    }
}

/// `LLMClientProtocol` adapter over the OpenAI Chat Completions API.
public actor OpenAIClient: LLMClientProtocol {
    /// The structured-output preparation strategy, injected at construction. Defaults to
    /// OpenAI's native JSON Schema `response_format` support.
    public let structuredOutputAdapter: any StructuredOutputAdapter
    private let client: OpenAI
    private let configuration: OpenAI.Configuration
    private let session: URLSession
    private let middlewares: [OpenAIMiddleware]
    private let modelName: String
    private let maxRetries: Int
    private let logger = Logger.module(named: "openai-client")

    /// Creates a client that talks to the given OpenAI-compatible endpoint over `URLSession`.
    ///
    /// - Parameters:
    ///   - apiKey: Sent as the bearer token on every request.
    ///   - modelName: The model to request completions from.
    ///   - host: The API host, overridable for self-hosted or proxy endpoints.
    ///   - port: The API port; omitted from the request URL when it's the scheme's default.
    ///   - scheme: The URL scheme (`https` or `http`).
    ///   - timeoutInterval: Per-request timeout, in seconds.
    ///   - maxRetries: Retry attempts for transient transport failures before any content has
    ///     streamed to the caller.
    ///   - structuredOutputAdapter: The structured-output preparation strategy to use.
    public init(
        apiKey: String,
        modelName: String = "gpt-4o",
        host: String = "api.openai.com",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        structuredOutputAdapter: any StructuredOutputAdapter = NativeJSONSchemaStructuredOutputAdapter()
    ) {
        self.init(
            apiKey: apiKey,
            modelName: modelName,
            host: host,
            port: port,
            scheme: scheme,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            session: URLSession.shared,
            middlewares: [],
            structuredOutputAdapter: structuredOutputAdapter
        )
    }

    package init(
        apiKey: String,
        modelName: String = "gpt-4o",
        host: String = "api.openai.com",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        session: URLSession,
        middlewares: [OpenAIMiddleware],
        structuredOutputAdapter: any StructuredOutputAdapter = NativeJSONSchemaStructuredOutputAdapter()
    ) {
        let configuration = OpenAI.Configuration(
            token: apiKey,
            host: host,
            port: port,
            scheme: scheme,
            timeoutInterval: timeoutInterval
        )
        client = OpenAI(configuration: configuration, session: session, middlewares: middlewares)
        self.configuration = configuration
        self.session = session
        self.middlewares = middlewares
        self.structuredOutputAdapter = structuredOutputAdapter
        self.modelName = modelName
        self.maxRetries = maxRetries
    }

    /// Streams a chat completion from the OpenAI API with the default (text-only) output
    /// modality.
    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            responseModalities: [.text],
            audioOutput: nil
        )
    }

    /// Streams a chat completion from the OpenAI API with explicit output modalities.
    ///
    /// Retries transient transport failures up to `maxRetries` times, but only before any
    /// content has been yielded to the caller — once streaming has started, a retry would
    /// duplicate content, so failures after that point are surfaced instead.
    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let client = self.client
        let logger = self.logger
        let maxRetries = self.maxRetries

        return CancellableAsyncThrowingStream.make(of: LLMStreamChunk.self) { continuation in
            let recoveryState = Mutex(LLMToolCallRecoveryState())

            do {
                try validateLLMMessageHistory(messages)
                let query = try await self.makeChatQuery(
                    messages: messages, tools: tools, toolChoice: toolChoice,
                    responseFormat: responseFormat, generationParameters: generationParameters,
                    responseModalities: responseModalities, audioOutput: audioOutput, stream: true
                )

                try await RetryPolicy.retry(
                    maxRetries: maxRetries,
                    shouldRetry: { error in
                        recoveryState.withLock { $0.shouldRetryAfterError } && RetryPolicy.isTransient(error: error)
                    },
                    operation: {
                        do {
                            let stream: AsyncThrowingStream<ChatStreamResult, Error> = client.chatsStream(query: query)

                            for try await result in stream {
                                if Task.isCancelled { break }
                                let chunk = result.toLLMStreamChunk(audioFormat: audioOutput?.format)
                                recoveryState.withLock {
                                    $0.observe(
                                        yieldedContent: chunk.carriesConsumerOutput,
                                        streamedToolCalls: chunk.choices.first?.delta.toolCalls != nil,
                                        finishedWithToolCalls: result.choices.contains(where: { $0.finishReason == .toolCalls })
                                    )
                                }

                                continuation.yield(chunk)
                            }

                            if !Task.isCancelled, recoveryState.withLock(\.shouldRecoverToolCalls) {
                                logger.warning("OpenAI stream finished with tool_calls but no streamed delta.toolCalls were received. Recovering tool calls from non-stream response.")
                                var recoveryQuery = query
                                recoveryQuery.stream = false
                                let recoveryResult = try await client.chats(query: recoveryQuery)
                                if !Task.isCancelled, let recoveryChunk = recoveryResult.toLLMToolCallRecoveryChunk() {
                                    continuation.yield(recoveryChunk)
                                }
                            }
                        } catch {
                            throw self.mapProviderError(error, provider: "OpenAI")
                        }
                    }
                )

                continuation.finish()
            } catch {
                logger.error("OpenAI stream error: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        }
    }

    /// Sends a non-streaming chat completion to the OpenAI API.
    public func chatCompletion(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        responseModalities: Set<ResponseModality> = [.text],
        audioOutput: AudioOutputOptions? = nil
    ) async throws -> LLMStreamChunk {
        do {
            try validateLLMMessageHistory(messages)
            let query = try makeChatQuery(
                messages: messages, tools: tools, toolChoice: toolChoice,
                responseFormat: responseFormat, generationParameters: generationParameters,
                responseModalities: responseModalities, audioOutput: audioOutput, stream: false
            )
            // The pinned OpenAI SDK validates HTTP status only for streaming requests, so a
            // non-2xx body is decoded as a `ChatResult` and fails with a `DecodingError` that
            // carries no status. Capture the status through a per-call middleware and map it to
            // `LLMServiceError.httpError` so retry policy sees the real status.
            let statusCapture = OpenAIHTTPStatusCaptureMiddleware()
            let nativeClient = OpenAI(
                configuration: configuration,
                session: session,
                middlewares: middlewares + [statusCapture]
            )
            let result = try await RetryPolicy.retry(maxRetries: maxRetries) {
                do {
                    return try await nativeClient.chats(query: query)
                } catch {
                    throw self.mapProviderError(
                        error,
                        provider: "OpenAI",
                        statusCode: statusCapture.capturedStatusCode()
                    )
                }
            }
            return result.toLLMStreamChunk(audioFormat: audioOutput?.format)
        } catch {
            throw mapProviderError(error, provider: "OpenAI")
        }
    }

    private func makeChatQuery(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?,
        stream: Bool
    ) throws -> ChatQuery {
        let mappedAudioOptions: ChatQuery.AudioOptions? = try audioOutput.map { options in
            guard let format = ChatQuery.AudioOptions.AudioOptionsResponseFormat(rawValue: options.format.rawValue),
                  let voice = ChatQuery.AudioOptions.AudioOptionsSpeechVoice(rawValue: options.voice)
            else { throw MultimodalContentError.unsupportedAudioVoice(options.voice, provider: .openAI) }
            return .init(format: format, voice: voice)
        }
        return ChatQuery(
            messages: try messages.map { try $0.toOpenAIMessageParam() },
            model: modelName,
            modalities: responseModalities.contains(.audio) ? [.text, .audio] : nil,
            audioOptions: mappedAudioOptions,
            frequencyPenalty: generationParameters?.frequencyPenalty,
            maxCompletionTokens: generationParameters?.maxTokens,
            parallelToolCalls: tools != nil ? false : nil,
            presencePenalty: generationParameters?.presencePenalty,
            responseFormat: responseFormat?.toOpenAIResponseFormat(),
            seed: generationParameters?.seed,
            temperature: generationParameters?.temperature,
            toolChoice: toolChoice?.toOpenAIToolChoice() ?? (tools != nil ? .auto : nil),
            tools: tools?.map { $0.toOpenAIToolParam() },
            topP: generationParameters?.topP,
            stream: stream,
            streamOptions: stream ? .init(includeUsage: true) : nil
        )
    }

    /// Sends a single user message and returns the full accumulated text response.
    ///
    /// Buffers the entire streamed response before returning; use one of the `chatStream`
    /// overloads directly for incremental output.
    public func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) async throws -> String {
        do {
            let stream = await self.chatStream(
                messages: [LLMMessage(role: .user, content: content)],
                tools: nil,
                toolChoice: nil,
                responseFormat: responseFormat,
                generationParameters: generationParameters
            )
            return try await accumulateStreamContent(from: stream)
        } catch {
            throw self.mapProviderError(error, provider: "OpenAI")
        }
    }

    /// Fetches the model IDs available from the OpenAI models API.
    ///
    /// Retries transient transport failures up to `maxRetries` times.
    public func fetchAvailableModels() async throws -> [String]? {
        let maxRetries = self.maxRetries
        return try await RetryPolicy.retry(maxRetries: maxRetries) {
            do {
                let models = try await self.client.models()
                return models.data.map { $0.id }
            } catch {
                throw self.mapProviderError(error, provider: "OpenAI")
            }
        }
    }

    package nonisolated func mapProviderError(_ error: Error, provider: String, statusCode: Int? = nil) -> Error {
        if error is CancellationError {
            return error
        }

        if let openAIError = error as? OpenAIError,
           case let .statusError(response, statusCode) = openAIError
        {
            return LLMServiceError.httpError(
                provider: provider,
                statusCode: statusCode,
                responseBody: "",
                retryAfter: ProviderHTTPFailure.parseRetryAfter(from: response)
            )
        }

        // The SDK's non-streaming path surfaces a `DecodingError` for a non-2xx body instead of
        // an `OpenAIError.statusError`; the captured status restores the HTTP failure mapping.
        if let statusCode, statusCode >= 400 {
            return LLMServiceError.httpError(
                provider: provider,
                statusCode: statusCode,
                responseBody: "",
                retryAfter: nil
            )
        }

        return error
    }
}
