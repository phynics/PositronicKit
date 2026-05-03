import Foundation
import PKShared

public extension LLMServiceProtocol {
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
        let resolvedOutput = request.structuredOutput.map {
            StructuredOutputExecution.apply(
                to: result.messages,
                rawPrompt: result.rawPrompt,
                provider: provider,
                output: $0
            )
        }

        let messages = resolvedOutput?.messages ?? result.messages
        let rawPrompt = resolvedOutput?.rawPrompt ?? result.rawPrompt
        let responseFormat = resolvedOutput?.responseFormat

        // Delegate to the configured provider implementation for streaming.
        let toolParams = request.tools.isEmpty ? nil : request.tools.map { $0.toLLMToolDefinition() }
        let stream = await chatStream(
            messages: messages,
            tools: toolParams,
            responseFormat: responseFormat,
            generationParameters: request.generationParameters,
            useUtilityModel: false,
            useFastModel: request.useFastModel
        )

        return LLMStreamResult(stream: stream, rawPrompt: rawPrompt)
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
        useUtilityModel: Bool,
        useFastModel: Bool
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let selectedClient: (any LLMClientProtocol)?
        if useFastModel {
            selectedClient = getFastClient() ?? getClient()
        } else if useUtilityModel {
            selectedClient = getUtilityClient() ?? getClient()
        } else {
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
