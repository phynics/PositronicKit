import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared

/// Owns turn preparation: saving inputs, gathering context, resolving session entities,
/// building the initial prompt, and recording the prompt-history snapshot.
///
/// Extracted from `ChatEngine` (PKARCH-001) so the preparation path can be tested and
/// reasoned about independently of the ReAct loop. `ChatEngine.execute` delegates to this
/// type for the pre-loop phase, then hands the resulting `ChatTurnContext` to
/// `TurnLoopController`.
struct TurnPreparer {
    let dependencies: ChatEngine.Dependencies
    let logger: Logger

    /// Consolidates all pre-turn logic: saving inputs, gathering context, resolving entities,
    /// and building the initial prompt.
    func prepareSession(
        timelineId: UUID,
        sendId: UUID,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]?,
        contextManager: ContextManager?,
        systemInstructions: String?,
        agentInstanceId: UUID?,
        maxTurns: Int,
        generationParameters: GenerationParameters?,
        structuredOutput: StructuredOutputRequest?,
        sidecars: [SidecarDirective] = [],
        includeSidecarMechanismPreamble: Bool = false,
        contextPipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil,
        assemblyPipeline: Pipeline<PromptAssemblyContext, PromptAssemblyEvent>? = nil,
        assemblyLogger: Logger? = nil
    ) async throws -> ChatTurnContext {
        // Sidecar directives steer generation only through prompt text (SDC-7). The per-turn
        // directive list is volatile (consumer-scheduled, changes turn-to-turn), so it rides
        // with the user query — the LAST prompt section — keeping the system prefix byte-stable
        // for provider prompt caching and PromptJournal stable-prefix diffing. An optional
        // semi-stable mechanism preamble can be layered into system instructions
        // (`SidecarSchemaComposer.mechanismPreamble`); the mechanism does not depend on it.
        let effectiveSystemInstructions: String? = includeSidecarMechanismPreamble
            ? ((systemInstructions ?? DefaultInstructions.system())
                + "\n\n" + SidecarSchemaComposer.mechanismPreamble)
            : systemInstructions
        let sidecarTurnInstructions: String? = sidecars.isEmpty
            ? nil
            : SidecarSchemaComposer.instructionBlock(directives: sidecars)

        // 1. Save new inputs (user message or externally submitted tool outputs)
        try await saveConversationSteps(timelineId: timelineId, message: message, toolOutputs: toolOutputs)

        // 2. Load conversation history and context
        let conversationMessages = try await dependencies.messageStore.fetchMessages(for: timelineId)
        let history = conversationMessages.map { $0.toMessage() }
        try validateToolHistory(history)
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
            turnInstructions: sidecarTurnInstructions,
            contextNotes: contextData.notes,
            memories: contextData.memories.map { $0.memory },
            chatHistory: history,
            tools: tools,
            workspaces: workspaceResult?.attached ?? [],
            primaryWorkspace: workspaceResult?.primary,
            requestOriginName: requestOriginName,
            systemInstructions: effectiveSystemInstructions,
            generationParameters: generationParameters
        )

        let promptHistory = await dependencies.promptHistoryRegistry.history(for: timelineId)
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
            sendId: sendId,
            agentInstanceId: agentInstanceId,
            modelName: modelName,
            maxTurns: maxTurns,
            systemInstructions: effectiveSystemInstructions,
            availableTools: tools,
            contextData: contextData,
            remoteDepth: currentRemoteDepth,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
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
            try await Self.externalToolOutputSubmissionGate.saveValidatedToolOutputs(
                toolOutputs,
                timelineId: timelineId,
                messageStore: dependencies.messageStore
            )
        }

        if !message.isEmpty {
            let userMsg = ConversationMessage(timelineId: timelineId, role: .user, content: message)
            try await dependencies.messageStore.saveMessage(userMsg)
        } else if toolOutputs?.isEmpty ?? true {
            throw ChatEngineError.missingInput
        }
    }

    private static let externalToolOutputSubmissionGate = ExternalToolOutputSubmissionGate()

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
                tagGenerator: { [utilityClient = dependencies.utilityClient] query in try await utilityClient.generateTags(for: query) },
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

    private func validateToolHistory(_ history: [Message]) throws {
        var pendingToolCallIds = Set<String>()

        for message in history {
            switch message.role {
            case .assistant:
                let toolCalls = message.toolCalls ?? []
                if !pendingToolCallIds.isEmpty {
                    throw ChatEngineError.danglingToolCall(id: pendingToolCallIds.min() ?? toolCalls.first?.id ?? "<unknown>")
                }
                if !toolCalls.isEmpty {
                    pendingToolCallIds = Set(toolCalls.map(\.id))
                }
            case .tool:
                guard let toolCallId = message.toolCallId else {
                    throw ChatEngineError.danglingToolResult(id: "<missing>")
                }
                guard pendingToolCallIds.remove(toolCallId) != nil else {
                    throw ChatEngineError.danglingToolResult(id: toolCallId)
                }
            case .user, .system, .summary:
                if !pendingToolCallIds.isEmpty {
                    throw ChatEngineError.danglingToolCall(id: pendingToolCallIds.min() ?? "<unknown>")
                }
            }
        }

        guard pendingToolCallIds.isEmpty else {
            throw ChatEngineError.danglingToolCall(id: pendingToolCallIds.min() ?? "<unknown>")
        }
    }
}

private actor ExternalToolOutputSubmissionGate {
    private var reservedToolOutputs: Set<ReservedToolOutput> = []

    func saveValidatedToolOutputs(
        _ toolOutputs: [ToolOutputSubmission],
        timelineId: UUID,
        messageStore: any MessageStoreProtocol
    ) async throws {
        guard !toolOutputs.isEmpty else { return }

        let existingMessages = try await messageStore.fetchMessages(for: timelineId)
        var pendingToolCallIds = Set<String>()

        // Only the latest uninterrupted assistant tool-call set is externally resumable.
        for message in existingMessages.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch message.messageRole {
            case .assistant:
                pendingToolCallIds = Set(Self.decodeToolCalls(from: message.toolCalls).map(\.id))
            case .tool:
                if let toolCallId = message.toolCallId {
                    pendingToolCallIds.remove(toolCallId)
                }
            case .user, .system, .summary:
                pendingToolCallIds.removeAll()
            }
        }

        for reservation in reservedToolOutputs where reservation.timelineId == timelineId {
            pendingToolCallIds.remove(reservation.toolCallId)
        }

        var reservations: [ReservedToolOutput] = []
        for output in toolOutputs {
            guard pendingToolCallIds.remove(output.toolCallId) != nil else {
                throw ToolError.unmatchedToolOutput(output.toolCallId)
            }
            let reservation = ReservedToolOutput(timelineId: timelineId, toolCallId: output.toolCallId)
            reservedToolOutputs.insert(reservation)
            reservations.append(reservation)
        }

        do {
            for output in toolOutputs {
                let msg = ConversationMessage(
                    timelineId: timelineId,
                    role: .tool,
                    content: output.output,
                    toolCallId: output.toolCallId
                )
                try await messageStore.saveMessage(msg)
            }
            for reservation in reservations {
                reservedToolOutputs.remove(reservation)
            }
        } catch {
            for reservation in reservations {
                reservedToolOutputs.remove(reservation)
            }
            throw error
        }
    }

    private static func decodeToolCalls(from json: String) -> [ToolCall] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? SerializationUtils.jsonDecoder.decode([ToolCall].self, from: data)) ?? []
    }
}

private struct ReservedToolOutput: Hashable {
    let timelineId: UUID
    let toolCallId: String
}
