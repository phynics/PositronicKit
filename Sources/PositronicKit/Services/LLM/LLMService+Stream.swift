import Foundation
import PKContracts
import PKUtilities

public extension LLMStreamClient {
    /// Stream a generation with full prompt building.
    func generationStreamWithContext(_ request: LLMGenerationRequest) async throws -> LLMStreamResult {
        let promptRequest = LLMPromptRequest(
            userQuery: request.userQuery,
            contextContributions: request.contextContributions,
            chatHistory: request.chatHistory,
            tools: request.tools,
            workspaces: request.workspaces,
            primaryWorkspace: request.primaryWorkspace,
            requestOriginName: request.requestOriginName,
            systemInstructions: request.systemInstructions,
            generationParameters: request.generationParameters
        )
        let result = try await PromptAssembler.prepare(promptRequest)
        let adapter = await structuredOutputAdapter(for: request.modelTier)
        let toolParams = request.tools.isEmpty ? nil : request.tools.map { $0.toLLMToolDefinition() }
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
            generationParameters: request.generationParameters,
            modelTier: request.modelTier
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
        await prepareIfNeeded()
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
            audioOutput: audioOutput
        )
    }

    /// Stream generation responses (low-level API)
    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await prepareIfNeeded()
        let resolved: ResolvedLLMClient
        do {
            resolved = try resolve(tier: modelTier)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        // Use provided parameters or default from configuration
        let params = generationParameters ?? resolved.generationParameters

        return await resolved.client.chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: params
        )
    }
}
