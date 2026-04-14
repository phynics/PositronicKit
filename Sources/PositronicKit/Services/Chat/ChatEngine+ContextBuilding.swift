import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared
import OpenAI

/// Errors thrown by `ChatEngine` during setup and execution.
public enum ChatEngineError: PKError {
    case llmServiceNotConfigured
    case missingInput

    public var errorDomain: String {
        PKErrorDomain.chat
    }

    public var errorCode: Int {
        switch self {
        case .llmServiceNotConfigured: return 9001
        case .missingInput: return 9002
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .llmServiceNotConfigured:
            return "The LLM service is not configured. Please set up your API endpoint and key."
        case .missingInput:
            return "A message or tool outputs must be provided to start a chat turn."
        }
    }
}

extension ChatEngine {
    /// Consolidates all pre-turn logic: saving inputs, gathering context, resolving entities,
    /// and building the initial prompt.
    func prepareSession(
        timelineId: UUID,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]?,
        contextManager: ContextManager?,
        systemInstructions: String?,
        agentInstanceId: UUID?,
        maxTurns: Int,
        generationParameters: GenerationParameters?,
        contextPipeline: ContextPipeline? = nil,
        assemblyPipeline: PromptAssemblyPipeline? = nil
    ) async throws -> ChatTurnContext {
        // 1. Save new inputs (user message or tool outputs from client)
        try await saveConversationSteps(timelineId: timelineId, message: message, toolOutputs: toolOutputs)

        // 2. Load conversation history and context
        let conversationMessages = try await messageStore.fetchMessages(for: timelineId)
        let history = conversationMessages.map { $0.toMessage() }
        let currentRemoteDepth = conversationMessages.map(\.remoteDepth).max() ?? 0
        let contextData = await fetchContext(
            contextManager: contextManager,
            message: message,
            history: history,
            pipeline: contextPipeline
        )

        // 3. Resolve workspaces and session entities
        let workspaceResult = await timelineManager.getWorkspaces(for: timelineId)
        let timeline = await timelineManager.getTimeline(id: timelineId)

        var agentInstance: AgentInstance?
        if let agentId = agentInstanceId {
            agentInstance = try? await agentInstanceStore.fetchAgentInstance(id: agentId)
        }

        var clientName: String?
        if let ownerId = workspaceResult?.primary?.ownerId,
           let client = try? await clientStore.fetchClient(id: ownerId)
        {
            clientName = client.displayName
        }

        // 4. Build the initial prompt messages
        let extensionSections = await timelineManager.gatherExtensionSections(
            timelineId: timelineId,
            agentInstanceId: agentInstance?.id,
            message: message
        )

        let promptRequest = LLMPromptRequest(
            userQuery: message,
            contextNotes: contextData.notes,
            memories: contextData.memories.map { $0.memory },
            chatHistory: history,
            tools: tools,
            workspaces: workspaceResult?.attached ?? [],
            primaryWorkspace: workspaceResult?.primary,
            clientName: clientName,
            systemInstructions: systemInstructions,
            generationParameters: generationParameters
        )

        let prompt = try await PromptBuilder.buildContext(
            promptRequest,
            agentInstance: agentInstance,
            timeline: timeline,
            extensionSections: extensionSections,
            overridePipeline: assemblyPipeline
        )

        // 5. Render once and reuse for messages + prompt history
        let renderedContent = await prompt.renderAll()
        let initialMessages = await prompt.toMessages(preRendered: renderedContent)

        // 6. Record prompt snapshot for cache tracking
        let promptHistory = TimelinePromptHistory()
        let diff = await promptHistory.record(sections: prompt.sections, renderedContent: renderedContent)
        logger.debug(
            "Prompt snapshot: \(prompt.sections.count) sections, ~\(prompt.estimatedTokens) tokens, \(diff.stablePrefixCount) stable prefix entries"
        )

        let modelName = await llmService.configuration.modelName

        return ChatTurnContext(
            timelineId: timelineId,
            agentInstanceId: agentInstanceId,
            modelName: modelName,
            maxTurns: maxTurns,
            systemInstructions: systemInstructions,
            availableTools: tools,
            contextData: contextData,
            remoteDepth: currentRemoteDepth,
            generationParameters: generationParameters,
            promptHistory: promptHistory,
            currentMessages: initialMessages,
            turnCount: 0,
            outputs: TurnOutputs()
        )
    }

    // MARK: - Internal Preparation Steps

    private func saveConversationSteps(
        timelineId: UUID,
        message: String,
        toolOutputs: [ToolOutputSubmission]?
    ) async throws {
        if let toolOutputs {
            for output in toolOutputs {
                let msg = ConversationMessage(
                    timelineId: timelineId,
                    role: .tool,
                    content: output.output,
                    toolCallId: output.toolCallId
                )
                try await messageStore.saveMessage(msg)
            }
        }

        if !message.isEmpty {
            let userMsg = ConversationMessage(timelineId: timelineId, role: .user, content: message)
            try await messageStore.saveMessage(userMsg)
        } else if toolOutputs?.isEmpty ?? true {
            throw ChatEngineError.missingInput
        }
    }

    private func fetchContext(
        contextManager: ContextManager?,
        message: String,
        history: [Message],
        pipeline: ContextPipeline? = nil
    ) async -> ContextData {
        guard let contextManager else { return ContextData() }

        do {
            let stream = await contextManager.gatherContext(
                for: message.isEmpty ? (history.last?.content ?? "") : message,
                history: history,
                tagGenerator: { [llmService] query in try await llmService.generateTags(for: query) },
                overridePipeline: pipeline
            )

            for try await event in stream {
                if case let .complete(data) = event {
                    return data
                }
            }
        } catch {
            logger.warning("Failed to gather context: \(error)")
        }
        return ContextData()
    }
}
