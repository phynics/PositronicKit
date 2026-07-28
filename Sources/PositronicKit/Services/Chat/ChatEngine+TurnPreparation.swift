import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

// MARK: - Turn Preparation

extension ChatEngine {
    /// Consolidates all pre-turn logic: saving inputs, gathering context, resolving entities,
    /// and building the initial prompt.
    ///
    /// PKRR-006: Input persistence is deferred until **after** history validation, context
    /// gathering, workspace lookup, and prompt assembly all succeed. If any preparation step
    /// throws, no user message or tool output is persisted, preventing orphan inputs on retry.
    /// The `sendId` serves as an in-memory idempotency key: a second call with the same
    /// `sendId` is rejected with ``ChatEngineError/duplicateSendId`` while the first is still
    /// processed (or has completed successfully). On failure the `sendId` is released so the
    /// caller may retry.
    func prepareSession(
        timelineId: UUID,
        sendId: UUID,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]?,
        turnBriefingBuilder: TurnBriefingBuilder?,
        systemInstructions: String?,
        agentInstanceId: UUID?,
        maxTurns: Int,
        generationParameters: GenerationParameters?,
        structuredOutput: StructuredOutputRequest?,
        sidecars: [SidecarDirective] = [],
        includeSidecarMechanismPreamble: Bool = false,
        contextPipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil,
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

        // 0. Validate input — at least a message or tool outputs must be provided.
        guard !message.isEmpty || !(toolOutputs?.isEmpty ?? true) else {
            throw ChatEngineError.missingInput
        }

        // 1. Idempotency — mark the sendId as in-progress. A duplicate sendId is rejected
        //    before any validation or persistence runs.
        guard await turnIdempotencyGate.checkAndMark(sendId: sendId) else {
            throw ChatEngineError.duplicateSendId(sendId)
        }

        // Track validated tool outputs so the catch block can release reservations.
        var validatedToolOutputs: [ToolOutputSubmission] = []

        do {
            // 2. Validate timeline existence before any preparation proceeds.
            try await dependencies.timelineManager.ensureTimelineExists(id: timelineId)

            // 3. Validate tool output submissions and reserve pending call IDs — no persistence.
            //    Already-persisted outputs are skipped (resumable batch support).
            validatedToolOutputs = try await externalToolOutputSubmissionGate.validate(
                toolOutputs ?? [],
                timelineId: timelineId,
                messageStore: dependencies.messageStore
            )

            // 4. Load existing conversation history (before new inputs are persisted).
            let conversationMessages = try await dependencies.messageStore.fetchMessages(for: timelineId)
            var history = conversationMessages.map { $0.toMessage() }
            let currentRemoteDepth = conversationMessages.map(\.remoteDepth).max() ?? 0

            // 5. Build an in-memory augmented history that includes the new tool outputs and
            //    user message, so validation, context gathering, and prompt assembly see the
            //    same history they would after persistence — without actually persisting yet.
            for output in validatedToolOutputs {
                history.append(Message(content: output.output, role: .tool, toolCallId: output.toolCallId))
            }
            if !message.isEmpty {
                history.append(Message(content: message, role: .user))
            }

            // 6. Validate the augmented tool-call history.
            try validateToolHistory(history)

            // 7. Load context
            let contextData = await fetchContext(
                turnBriefingBuilder: turnBriefingBuilder,
                message: message,
                history: history,
                pipeline: contextPipeline
            )

            // 8. Resolve workspaces and session entities
            let workspaceResult = try await dependencies.timelineManager.getWorkspaces(for: timelineId)
            await dependencies.timelineManager.touchTimeline(id: timelineId)
            let timeline = await dependencies.timelineManager.timeline(id: timelineId)

            var agentInstance: AgentInstance?
            if let agentId = agentInstanceId {
                agentInstance = try? await dependencies.agentInstanceStore.fetchAgentInstance(id: agentId)
            }

            let requestOriginId = workspaceResult.primary?.originId
                ?? workspaceResult.attached.lazy.compactMap(\.originId).first

            var requestOriginName: String?
            if let originId = requestOriginId,
               let origin = try? await dependencies.requestOriginStore.fetchOrigin(id: originId)
            {
                requestOriginName = origin.displayName
            }

            // 9. Build the initial prompt messages
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
                workspaces: workspaceResult.attached,
                primaryWorkspace: workspaceResult.primary,
                requestOriginName: requestOriginName,
                systemInstructions: effectiveSystemInstructions,
                generationParameters: generationParameters
            )

            let promptHistory = await dependencies.promptHistoryRegistry.history(for: timelineId)
            let structuredDiff = await promptHistory.structuredDiffHint()
            let providerConfig = await dependencies.llmService.configuration.activeProviderConfiguration
            let budget = try ChatEngine.makeTokenBudget(
                contextWindowTokens: providerConfig.contextWindowTokens,
                maxOutputTokens: generationParameters?.maxTokens
            )

            let renderedPrompt = try await PromptAssembler.assemble(
                promptRequest,
                agentInstance: agentInstance,
                timeline: timeline,
                extensionSections: extensionSections,
                options: PromptAssemblyOptions(
                    tokenBudget: budget,
                    logger: assemblyLogger,
                    structuredDiff: structuredDiff
                )
            )

            // 10. Commit persistence — AFTER all validation and preparation succeeds.
            //     Tool outputs are committed first (resumable batch), then the user message.
            //     If either fails, the sendId is released so the caller can retry; the
            //     resumable batch ensures already-persisted tool outputs are not duplicated.
            try await externalToolOutputSubmissionGate.commit(
                validatedToolOutputs,
                timelineId: timelineId,
                messageStore: dependencies.messageStore
            )
            if !message.isEmpty {
                let userMsg = ConversationMessage(timelineId: timelineId, role: .user, content: message)
                try await dependencies.messageStore.saveMessage(userMsg)
            }

            // 11. Reuse the final rendered artifact for messages + prompt history
            let initialMessages = renderedPrompt.buildMessages()
            let resolvedSections = renderedPrompt.sections

            // 12. Record prompt snapshot for cache tracking
            let update = await promptHistory.update(prompt: renderedPrompt)
            guard let diff = update.diff else {
                preconditionFailure("Prompt updates must always produce a prompt diff")
            }
            logger.debug(
                "Prompt journal updated: added=\(diff.added.count) removed=\(diff.removed.count) changed=\(diff.changed.count)",
                metadata: [
                    LogKeys.timelineID: .string(timelineId.uuidString),
                    LogKeys.sendID: .string(sendId.uuidString),
                    LogKeys.turnIndex: .string("0"),
                    "addedSections": .string("\(diff.added.count)"),
                    "removedSections": .string("\(diff.removed.count)"),
                    "changedSections": .string("\(diff.changed.count)"),
                ]
            )
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

            let modelName = providerConfig.modelName

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
        } catch {
            // Release the idempotency marker so the caller can retry with the same sendId.
            await turnIdempotencyGate.release(sendId: sendId)
            // Release any tool-output reservations made during validation.
            await externalToolOutputSubmissionGate.releaseReservations(
                timelineId: timelineId,
                toolCallIds: validatedToolOutputs.map(\.toolCallId)
            )
            throw error
        }
    }
}

// MARK: - Preparation Steps

private extension ChatEngine {
    func fetchContext(
        turnBriefingBuilder: TurnBriefingBuilder?,
        message: String,
        history: [Message],
        pipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil
    ) async -> ContextData {
        guard let turnBriefingBuilder else { return ContextData() }

        do {
            let stream = await turnBriefingBuilder.gatherContext(
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

    func validateToolHistory(_ history: [Message]) throws {
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

// MARK: - Turn Idempotency Gate

private let turnIdempotencyGate = TurnIdempotencyGate()

private actor TurnIdempotencyGate {
    private var processedSendIds: Set<UUID> = []

    /// Marks `sendId` as in-progress. Returns `true` if newly marked, `false` if already
    /// processed or in progress.
    func checkAndMark(sendId: UUID) -> Bool {
        guard !processedSendIds.contains(sendId) else { return false }
        processedSendIds.insert(sendId)
        return true
    }

    /// Releases the idempotency marker so the caller can retry with the same `sendId`.
    func release(sendId: UUID) {
        processedSendIds.remove(sendId)
    }
}

// MARK: - External Tool Output Submission Gate

private let externalToolOutputSubmissionGate = ExternalToolOutputSubmissionGate()

private actor ExternalToolOutputSubmissionGate {
    private var reservedToolOutputs: Set<ReservedToolOutput> = []

    /// Validates that each tool output matches a pending assistant tool call and reserves the
    /// call ID — **without persisting**. Already-persisted outputs are skipped so a partially
    /// failed batch can be safely retried (resumable batch support).
    ///
    /// - Returns: The subset of `toolOutputs` that are validated and still need persistence.
    func validate(
        _ toolOutputs: [ToolOutputSubmission],
        timelineId: UUID,
        messageStore: any MessageStoreProtocol
    ) async throws -> [ToolOutputSubmission] {
        guard !toolOutputs.isEmpty else { return [] }

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

        // Remove call IDs already reserved by concurrent submissions.
        for reservation in reservedToolOutputs where reservation.timelineId == timelineId {
            pendingToolCallIds.remove(reservation.toolCallId)
        }

        // Track already-persisted tool call IDs for resumable batch support.
        let persistedToolCallIds = Set(
            existingMessages
                .filter { $0.messageRole == .tool }
                .compactMap { $0.toolCallId }
        )

        var validated: [ToolOutputSubmission] = []
        for output in toolOutputs {
            // Skip outputs already persisted by a previous (partial) batch.
            if persistedToolCallIds.contains(output.toolCallId) {
                continue
            }
            guard pendingToolCallIds.remove(output.toolCallId) != nil else {
                throw ToolError.unmatchedToolOutput(output.toolCallId)
            }
            let reservation = ReservedToolOutput(timelineId: timelineId, toolCallId: output.toolCallId)
            reservedToolOutputs.insert(reservation)
            validated.append(output)
        }

        return validated
    }

    /// Persists validated tool output messages. Already-persisted outputs are skipped so a
    /// partially failed batch can be retried without duplication (resumable batch support).
    func commit(
        _ validatedOutputs: [ToolOutputSubmission],
        timelineId: UUID,
        messageStore: any MessageStoreProtocol
    ) async throws {
        guard !validatedOutputs.isEmpty else { return }

        // Re-check for already-persisted outputs — a prior partial batch may have persisted
        // some messages before failing.
        let existingMessages = try await messageStore.fetchMessages(for: timelineId)
        let persistedToolCallIds = Set(
            existingMessages
                .filter { $0.messageRole == .tool }
                .compactMap { $0.toolCallId }
        )

        for output in validatedOutputs {
            if persistedToolCallIds.contains(output.toolCallId) { continue }
            let msg = ConversationMessage(
                timelineId: timelineId,
                role: .tool,
                content: output.output,
                toolCallId: output.toolCallId
            )
            try await messageStore.saveMessage(msg)
        }

        // Release reservations for all validated outputs (persisted or already-present).
        for output in validatedOutputs {
            reservedToolOutputs.remove(ReservedToolOutput(timelineId: timelineId, toolCallId: output.toolCallId))
        }
    }

    /// Releases reservations for the specified tool call IDs (on preparation failure).
    func releaseReservations(timelineId: UUID, toolCallIds: [String]) {
        for toolCallId in toolCallIds {
            reservedToolOutputs.remove(ReservedToolOutput(timelineId: timelineId, toolCallId: toolCallId))
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
