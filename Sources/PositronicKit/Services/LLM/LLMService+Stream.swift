import Foundation
import PKShared

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
        let provider = await configuration.provider
        let toolParams = request.tools.isEmpty ? nil : request.tools.map { $0.toLLMToolDefinition() }
        let preparedOutput = request.structuredOutput.map {
            StructuredOutputExecution.prepareRequest(
                messages: result.messages,
                tools: toolParams,
                provider: provider,
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
    /// Stream chat responses (low-level API)
    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let selectedClient: (any LLMClientProtocol)?
        switch modelTier {
        case .fast:
            selectedClient = getFastClient() ?? getClient()
        case .utility:
            selectedClient = getUtilityClient() ?? getClient()
        case .primary:
            selectedClient = getClient()
        }

        guard let client = selectedClient else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: LLMServiceError.notConfigured)
            }
        }

        // Use provided parameters or default from configuration
        let params = generationParameters ?? configuration.generationParameters

        return await client.chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: params
        )
    }
}
