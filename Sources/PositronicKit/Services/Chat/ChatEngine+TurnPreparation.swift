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
        sidecarCommitPolicy: SidecarCommitPolicy = .everyRoundTrip,
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
        guard await TurnIdempotencyGate.shared.checkAndMark(sendId: sendId) else {
            throw ChatEngineError.duplicateSendId(sendId)
        }

        // Track validated tool outputs so the catch block can release reservations.
        var validatedToolOutputs: [ToolOutputSubmission] = []

        do {
            // 2. Validate timeline existence before any preparation proceeds.
            try await dependencies.timelineManager.ensureTimelineExists(id: timelineId)

            // 3. Validate tool output submissions and reserve pending call IDs — no persistence.
            //    Already-persisted outputs are skipped (resumable batch support).
            validatedToolOutputs = try await ExternalToolOutputSubmissionGate.shared.validate(
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
                history.append(Message(content: output.output, role: .tool, toolCallID: output.toolCallID))
            }
            if !message.isEmpty {
                history.append(Message(content: message, role: .user))
            }

            // 6. Validate the augmented tool-call history.
            try validateToolHistory(history)

            // 7. Load context
            let contextResult = try await fetchContext(
                turnBriefingBuilder: turnBriefingBuilder,
                message: message,
                history: history,
                pipeline: contextPipeline
            )
            var turnDiagnostics = contextResult.diagnostics
            let contextData = contextResult.data

            // 8. Resolve workspaces and session entities
            let workspaceResult = try await dependencies.timelineManager.getWorkspaces(for: timelineId)
            turnDiagnostics += workspaceResult.degradations.map {
                TurnDiagnostic(
                    dependency: .workspace,
                    operation: $0.operation,
                    entityID: $0.entityID,
                    errorIdentity: $0.errorIdentity,
                    message: $0.message
                )
            }
            turnDiagnostics += await dependencies.timelineManager.consumeDegradations(for: timelineId)
            try enforceRequired(turnDiagnostics)
            await dependencies.timelineManager.touchTimeline(id: timelineId)
            let timeline = await dependencies.timelineManager.timeline(id: timelineId)

            var agentInstance: AgentInstance?
            if let agentId = agentInstanceId {
                do {
                    agentInstance = try await dependencies.agentInstanceStore.fetchAgentInstance(id: agentId)
                    if agentInstance == nil {
                        let error = AgentInstanceError.instanceNotFound(agentId)
                        turnDiagnostics.append(diagnostic(for: .agent, operation: "fetchAgentInstance", entityId: agentId.uuidString, error: error))
                    }
                } catch {
                    turnDiagnostics.append(diagnostic(for: .agent, operation: "fetchAgentInstance", entityId: agentId.uuidString, error: error))
                    try enforceRequired(turnDiagnostics)
                }
            }

            let requestOriginId = workspaceResult.primary?.originID
                ?? workspaceResult.attached.lazy.compactMap(\.originID).first

            var requestOriginName: String?
            if let originId = requestOriginId {
                do {
                    requestOriginName = try await dependencies.requestOriginStore.fetchOrigin(id: originId)?.displayName
                } catch {
                    turnDiagnostics.append(diagnostic(for: .origin, operation: "fetchOrigin", entityId: originId.uuidString, error: error))
                }
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
            try await ExternalToolOutputSubmissionGate.shared.commit(
                validatedToolOutputs,
                timelineId: timelineId,
                messageStore: dependencies.messageStore
            )
            if !message.isEmpty {
                let userMsg = ConversationMessage(timelineID: timelineId, role: .user, content: message)
                try await dependencies.messageStore.saveMessage(userMsg)
            }

            // 11. Reuse the final rendered artifact for messages + prompt history
            let initialMessages = renderedPrompt.buildMessages()
            let resolvedSections = renderedPrompt.sections

            // 12. Record prompt snapshot for cache tracking
            let update: PromptHistoryUpdate
            do {
                update = try await promptHistory.update(prompt: renderedPrompt)
            } catch {
                logger.error("Prompt history update failed; aborting turn before returning context", metadata: [
                    LogKeys.timelineID: .string(timelineId.uuidString),
                    LogKeys.sendID: .string(sendId.uuidString),
                    "error": .string(String(describing: error)),
                ])
                throw ChatEngineError.promptHistoryInconsistent(String(describing: error))
            }
            guard let diff = update.diff else {
                logger.error("Prompt history update produced no diff; aborting turn", metadata: [
                    LogKeys.timelineID: .string(timelineId.uuidString),
                    LogKeys.sendID: .string(sendId.uuidString),
                    "journalState": .string("update_without_diff"),
                ])
                throw ChatEngineError.promptHistoryInconsistent("update produced no prompt diff")
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
                            nodeId: $0.nodeID,
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
                sidecarCommitPolicy: sidecarCommitPolicy,
                diagnostics: turnDiagnostics,
                promptHistory: promptHistory,
                renderedPrompt: renderedPrompt,
                promptHistoryUpdate: update,
                currentMessages: initialMessages,
                turnCount: 0,
                outputs: TurnOutputs()
            )
        } catch {
            // Release the idempotency marker so the caller can retry with the same sendId.
            await TurnIdempotencyGate.shared.release(sendId: sendId)
            // Release any tool-output reservations made during validation.
            await ExternalToolOutputSubmissionGate.shared.releaseReservations(
                timelineId: timelineId,
                toolCallIds: validatedToolOutputs.map(\.toolCallID)
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
    ) async throws -> (data: ContextData, diagnostics: [TurnDiagnostic]) {
        guard let turnBriefingBuilder else { return (ContextData(), []) }

        do {
            let stream = await turnBriefingBuilder.gatherContext(
                for: message.isEmpty ? (history.last?.content ?? "") : message,
                history: history,
                tagGenerator: { [utilityClient = dependencies.utilityClient] query in try await utilityClient.generateTags(for: query) },
                overridePipeline: pipeline
            )

            for try await event in stream {
                if case let .complete(data) = event {
                    return (data, [])
                }
            }
        } catch {
            let diagnostic = diagnostic(for: .context, operation: "gatherContext", entityId: "turn", error: error)
            if dependencies.degradationPolicy == .failRequired {
                throw TurnDegradationError.required(diagnostic, error)
            }
            logger.warning("Failed to gather context: \(error)")
            return (ContextData(), [diagnostic])
        }
        let diagnostic = TurnDiagnostic(
            dependency: .context,
            operation: "gatherContext",
            entityId: "turn",
            errorIdentity: .init(domain: PKErrorDomain.context, code: 9011),
            message: "Context gathering completed without context data."
        )
        if dependencies.degradationPolicy == .failRequired {
            throw TurnDegradationError.required(diagnostic, TurnBriefingBuilderError.persistenceFailed(NSError(domain: "PositronicKit", code: 1)))
        }
        return (ContextData(), [diagnostic])
    }

    func diagnostic(for dependency: TurnDependency, operation: String, entityId: String, error: Error) -> TurnDiagnostic {
        TurnDiagnostic(
            dependency: dependency,
            operation: operation,
            entityId: entityId,
            errorIdentity: ChatEvent.ErrorIdentity.extracting(from: error),
            message: ErrorKit.userFriendlyMessage(for: error)
        )
    }

    func enforceRequired(_ diagnostics: [TurnDiagnostic]) throws {
        guard dependencies.degradationPolicy == .failRequired,
              let diagnostic = diagnostics.first(where: { diagnostic in
                  switch diagnostic.dependency {
                  case .context, .agent:
                      return true
                  case .workspace:
                      // A missing optional attachment is observable but does not make the
                      // timeline unusable. Store outages and resolver failures remain fatal.
                      return diagnostic.errorIdentity?.code != 3004
                  case .origin:
                      return false
                  }
              })
        else { return }
        throw TurnDegradationError.required(
            diagnostic,
            NSError(domain: diagnostic.errorIdentity?.domain ?? PKErrorDomain.chat, code: diagnostic.errorIdentity?.code ?? 9010)
        )
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
                guard let toolCallID = message.toolCallID else {
                    throw ChatEngineError.danglingToolResult(id: "<missing>")
                }
                guard pendingToolCallIds.remove(toolCallID) != nil else {
                    throw ChatEngineError.danglingToolResult(id: toolCallID)
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
