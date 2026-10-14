import Foundation
import PKContracts
import PKUtilities

public extension LLMStreamClient {
    /// Assembles the prompt, applies structured output when requested, and streams from the
    /// selected tier. See ``LLMStreamClient/generationStreamWithContext(_:)``.
    func generationStreamWithContext(_ request: LLMGenerationRequest) async throws -> LLMStreamResult {
        let promptRequest = request.prompt
        let result = try await PromptAssembler.prepare(promptRequest)
        let adapter = await structuredOutputAdapter(for: request.modelTier)
        let toolParams = promptRequest.tools.isEmpty ? nil : promptRequest.tools.map { $0.toLLMToolDefinition() }
        let preparedOutput = request.structuredOutput.map {
            StructuredOutputExecution.prepareRequest(
                messages: result.messages,
                tools: toolParams,
                adapter: adapter,
                output: $0
            )
        }

        let messages = preparedOutput?.messages ?? result.messages
        let rawPrompt = if let augmentation = preparedOutput?.promptAugmentation {
            result.rawPrompt + augmentation
        } else {
            result.rawPrompt
        }
        let responseFormat = preparedOutput?.responseFormat
        let toolChoice = preparedOutput?.toolChoice

        // Delegate to the configured provider implementation for streaming.
        let resolvedTools = preparedOutput?.tools ?? toolParams
        let stream = await generationStream(
            messages: messages,
            tools: resolvedTools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: promptRequest.generationParameters,
            modelTier: request.modelTier,
            promptCache: promptRequest.promptCache
        )

        let resolvedStream = if let syntheticToolName = preparedOutput?.syntheticToolName {
            StructuredOutputExecution.rewriteSyntheticToolStream(stream, syntheticToolName: syntheticToolName)
        } else {
            stream
        }

        return LLMStreamResult(stream: resolvedStream, rawPrompt: rawPrompt)
    }
}

public extension LLMService {
    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await generationStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            promptCache: nil
        )
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?,
        promptCache: PromptCacheDirective?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let resolved: ResolvedLLMClient
        do {
            resolved = try resolve(tier: modelTier)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        let parameters = generationParameters ?? resolved.generationParameters
        return await resolved.client.chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: parameters,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            promptCache: Self.honoredPromptCache(promptCache, for: resolved.client)
        )
    }

    func generationCompletion(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async throws -> LLMStreamChunk {
        try await generationCompletion(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            promptCache: nil
        )
    }

    func generationCompletion(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?,
        promptCache: PromptCacheDirective?
    ) async throws -> LLMStreamChunk {
        let resolved = try resolve(tier: modelTier)
        let parameters = generationParameters ?? resolved.generationParameters
        return try await resolved.client.chatCompletion(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: parameters,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            promptCache: Self.honoredPromptCache(promptCache, for: resolved.client)
        )
    }

    /// Returns the directive a client can act on, or `nil` when the client declares no prompt
    /// caching. Adapters own the translation of retention windows and breakpoints.
    static func honoredPromptCache(
        _ directive: PromptCacheDirective?,
        for client: any LLMClientProtocol
    ) -> PromptCacheDirective? {
        guard let directive else { return nil }
        switch client.promptCachingCapability {
        case .none:
            return nil
        case .automatic, .explicit:
            return directive
        }
    }
}
