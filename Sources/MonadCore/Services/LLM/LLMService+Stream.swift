import Foundation
import MonadShared
import OpenAI

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
            clientName: request.clientName,
            systemInstructions: request.systemInstructions,
            generationParameters: request.generationParameters
        )
        let result = try await PromptBuilder.buildPrompt(promptRequest)
        let messages = result.messages
        let rawPrompt = result.rawPrompt

        // Delegate to client for streaming
        let toolParams = request.tools.isEmpty ? nil : request.tools.map { $0.toToolParam() }
        let stream = await chatStream(
            messages: messages,
            tools: toolParams,
            responseFormat: request.responseFormat,
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
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]?,
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel: Bool,
        useFastModel: Bool
    ) async -> AsyncThrowingStream<ChatStreamResult, Error> {
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
            responseFormat: responseFormat,
            generationParameters: params
        )
    }
}
