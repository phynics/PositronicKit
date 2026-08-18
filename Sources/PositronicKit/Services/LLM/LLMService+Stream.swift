import Foundation
import PKShared
import PKUtilities

public extension LLMStreamClient {
    /// Stream chat with full prompt building (includes notes, history, etc.)
    func chatStreamWithContext(_ request: LLMChatRequest) async throws -> LLMStreamResult {
        let promptRequest = LLMPromptRequest(
            userQuery: request.userQuery,
            contextNotes: request.contextNotes,
            memories: request.memories,
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
        let stream = await chatStream(
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
    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await awaitPreparation()
        let selectedClient: (any LLMClientProtocol)? = switch modelTier {
        case .fast: fastClient() ?? client()
        case .utility: utilityClient() ?? client()
        case .primary: client()
        }
        guard let selectedClient else {
            return AsyncThrowingStream { $0.finish(throwing: LLMServiceError.notConfigured) }
        }
        let parameters = generationParameters ?? configuration.activeProviderConfiguration.generationParameters
        return await selectedClient.chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: parameters,
            responseModalities: responseModalities,
            audioOutput: audioOutput
        )
    }

    /// Stream chat responses (low-level API)
    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await awaitPreparation()
        let selectedClient: (any LLMClientProtocol)?
        switch modelTier {
        case .fast:
            selectedClient = fastClient() ?? client()
        case .utility:
            selectedClient = utilityClient() ?? client()
        case .primary:
            selectedClient = client()
        }

        guard let client = selectedClient else {
            let error: LLMServiceError = configuration.isValid
                ? .clientNotResolved(provider: configuration.activeProvider.rawValue)
                : .notConfigured
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        // Use provided parameters or default from configuration
        let params = generationParameters ?? configuration.activeProviderConfiguration.generationParameters

        return await client.chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: params
        )
    }
}
