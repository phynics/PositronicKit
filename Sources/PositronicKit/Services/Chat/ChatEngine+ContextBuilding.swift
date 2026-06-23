import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared

/// Errors thrown by `ChatEngine` during setup and execution.
enum ChatEngineError: PKError {
    case llmServiceNotConfigured
    case missingInput

    var errorDomain: String {
        PKErrorDomain.chat
    }

    var errorCode: Int {
        switch self {
        case .llmServiceNotConfigured: return 9001
        case .missingInput: return 9002
        }
    }

    var userFriendlyMessage: String {
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
        structuredOutput: StructuredOutputRequest?,
        contextPipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil,
        assemblyPipeline: Pipeline<PromptAssemblyContext, PromptAssemblyEvent>? = nil,
        assemblyLogger: Logger? = nil
    ) async throws -> ChatTurnContext {
        // 1. Save new inputs (user message or externally submitted tool outputs)
        try await saveConversationSteps(timelineId: timelineId, message: message, toolOutputs: toolOutputs)

        // 2. Load conversation history and context
        let conversationMessages = try await dependencies.messageStore.fetchMessages(for: timelineId)
        let history = conversationMessages.map { $0.toMessage() }
        let currentRemoteDepth = conversationMessages.map(\.remoteDepth).max() ?? 0
        let contextData = await fetchContext(
            contextManager: contextManager,
            message: message,
            history: history,
            pipeline: contextPipeline
        )

        // 3. Resolve workspaces and session entities
        let workspaceResult = await dependencies.timelineManager.getWorkspaces(for: timelineId)
        let timeline = await dependencies.timelineManager.getTimeline(id: timelineId)

        var agentInstance: AgentInstance?
        if let agentId = agentInstanceId {
            agentInstance = try? await dependencies.agentInstanceStore.fetchAgentInstance(id: agentId)
        }

        let requestOriginId = workspaceResult?.primary?.originId
            ?? workspaceResult?.attached.lazy.compactMap(\.originId).first

        var requestOriginName: String?
        if let originId = requestOriginId,
           let origin = try? await dependencies.requestOriginStore.fetchOrigin(id: originId)
        {
            requestOriginName = origin.displayName
        }

        // 4. Build the initial prompt messages
        let extensionSections = await dependencies.timelineManager.gatherExtensionSections(
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
            requestOriginName: requestOriginName,
            systemInstructions: systemInstructions,
            generationParameters: generationParameters
        )

        let promptHistory = TimelinePromptHistory()
        let structuredDiff = await promptHistory.structuredDiffHint()
        let budget = generationParameters?.maxTokens.map {
            TokenBudget(maxTokens: $0, reserveForResponse: max(256, $0 / 5))
        }

        let renderedPrompt = try await PromptAssembler.assemble(
            promptRequest,
            agentInstance: agentInstance,
            timeline: timeline,
            extensionSections: extensionSections,
            options: PromptAssemblyOptions(
                overridePipeline: assemblyPipeline,
                tokenBudget: budget,
                logger: assemblyLogger,
                structuredDiff: structuredDiff
            )
        )

        // 5. Reuse the final rendered artifact for messages + prompt history
        let initialMessages = renderedPrompt.buildMessages()
        let resolvedSections = renderedPrompt.sections

        // 6. Record prompt snapshot for cache tracking
        let update = await promptHistory.update(prompt: renderedPrompt)
        guard let diff = update.diff else {
            preconditionFailure("Prompt updates must always produce a prompt diff")
        }
        logger.debug(
            "Prompt snapshot: \(resolvedSections.count) sections, ~\(renderedPrompt.estimatedTokens) tokens, \(diff.stablePrefixCount) stable prefix entries"
        )
        if update.didCompact {
            logger.debug("Prompt history append state compacted after prompt update")
        }

        if let report = renderedPrompt.compressionReport {
            let metrics = StructuredCompressionMetrics(
                totalNodes: report.nodeReports.count,
                summarizedNodes: report.nodeReports.filter {
                    if case .summarize = $0.action { return true }
                    return false
                }.count,
                droppedNodes: report.nodeReports.filter {
                    if case .drop = $0.action { return true }
                    return false
                }.count,
                cacheHits: report.nodeReports.filter { $0.cacheHit }.count,
                nodeMetrics: report.nodeReports.map {
                    StructuredCompressionNodeMetric(
                        nodeId: $0.nodeId,
                        path: $0.path,
                        action: String(describing: $0.action),
                        beforeTokens: $0.beforeTokens,
                        afterTokens: $0.afterTokens,
                        cacheHit: $0.cacheHit
                    )
                }
            )
            logger.debug("Structured compression metrics: \(metrics)")
        }

        let modelName = await dependencies.llmService.configuration.modelName

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
            structuredOutput: structuredOutput,
            promptHistory: promptHistory,
            renderedPrompt: renderedPrompt,
            promptHistoryUpdate: update,
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
                try await dependencies.messageStore.saveMessage(msg)
            }
        }

        if !message.isEmpty {
            let userMsg = ConversationMessage(timelineId: timelineId, role: .user, content: message)
            try await dependencies.messageStore.saveMessage(userMsg)
        } else if toolOutputs?.isEmpty ?? true {
            throw ChatEngineError.missingInput
        }
    }

    private func fetchContext(
        contextManager: ContextManager?,
        message: String,
        history: [Message],
        pipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil
    ) async -> ContextData {
        guard let contextManager else { return ContextData() }

        do {
            let stream = await contextManager.gatherContext(
                for: message.isEmpty ? (history.last?.content ?? "") : message,
                history: history,
                tagGenerator: { [llmService = dependencies.llmService] query in try await llmService.generateTags(for: query) },
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
