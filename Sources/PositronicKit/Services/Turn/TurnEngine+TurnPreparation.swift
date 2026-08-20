import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

// MARK: - Turn Preparation

extension TurnEngine {
    enum PreparedSession {
        case ready(TurnContext)
        case existing(TurnAdmission)
    }

    struct AgentPreflight: Sendable {
        let instance: Agent?
        let diagnostics: [TurnDiagnostic]
    }

    /// Resolves a requested agent and validates its exclusive thread attachment before provider
    /// readiness or turn persistence.
    func preflightAgent(id agentId: UUID?, threadID: UUID) async throws -> AgentPreflight {
        guard let agentId else {
            return AgentPreflight(instance: nil, diagnostics: [])
        }

        let instance: Agent?
        do {
            instance = try await dependencies.agentStore.fetchAgent(id: agentId)
        } catch {
            let diagnostic = diagnostic(
                for: .agent,
                operation: "fetchAgent",
                entityId: agentId.uuidString,
                error: error
            )
            try enforceRequired([diagnostic])
            return AgentPreflight(instance: nil, diagnostics: [diagnostic])
        }

        guard let instance else {
            let error = AgentError.agentNotFound(agentId)
            if dependencies.degradationPolicy == .failRequired {
                throw error
            }
            return AgentPreflight(
                instance: nil,
                diagnostics: [diagnostic(
                    for: .agent,
                    operation: "fetchAgent",
                    entityId: agentId.uuidString,
                    error: error
                )]
            )
        }
        let thread: Thread?
        do {
            thread = try await dependencies.threadManager.threadStore.fetchThread(id: threadID)
        } catch {
            throw ThreadError.unavailable
        }

        guard let thread else {
            throw ThreadError.threadNotFound
        }
        guard thread.attachedAgentID == agentId else {
            throw AgentError.threadAgentMismatch(
                threadID: threadID,
                agentID: agentId,
                attachedAgentID: thread.attachedAgentID
            )
        }

        return AgentPreflight(instance: instance, diagnostics: [])
    }

    /// Consolidates all pre-turn logic: saving inputs, gathering context, resolving entities,
    /// and building the initial prompt.
    ///
    /// PKRR-006: Input persistence is deferred until **after** history validation, context
    /// gathering, workspace lookup, prompt assembly, and the initial prompt-history transition
    /// all succeed. If any preparation step throws, no new user message or tool output is
    /// persisted, preventing orphan inputs on retry.
    /// The `requestId` gates the in-memory turn and is reused as the user's existing message identity
    /// for retry-safe persistence. A second call with the same `requestId` is rejected with
    /// ``TurnEngineError/duplicateRequestID`` while the first is still processed (or has completed
    /// successfully). Preparation failures release the `requestId` here; stream-loop failures
    /// release it when their terminal outcome is known.
    func prepareSession(
        threadID: UUID,
        turnID: UUID,
        requestId: UUID,
        messageContent: MessageContent,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]?,
        turnBriefingBuilder: TurnBriefingBuilder?,
        systemInstructions: String?,
        agentId: UUID?,
        agent: Agent?,
        agentDiagnostics: [TurnDiagnostic],
        maxModelRounds: Int,
        generationParameters: GenerationParameters?,
        structuredOutput: StructuredOutputRequest?,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyModelRound,
        includeSidecarMechanismPreamble: Bool = false,
        contextPipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil,
        assemblyLogger: Logger? = nil,
        responseModalities: Set<ResponseModality> = [.text],
        audioOutput: AudioOutputOptions? = nil
    ) async throws -> PreparedSession {
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
        let hasMessage = !messageContent.parts.isEmpty
            && (!messageContent.isTextOnly || !messageContent.text.isEmpty)
        guard hasMessage || !(toolOutputs?.isEmpty ?? true) else {
            throw TurnEngineError.missingInput
        }

        try messageContent.validateMedia()
        let initialConfiguration = await dependencies.llmService.configuration
        let initialProviderConfig = initialConfiguration.activeProviderConfiguration
        try validateMultimodalRequest(
            content: messageContent,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            capabilities: initialProviderConfig.capabilities,
            provider: initialConfiguration.activeProvider
        )

        // Track validated tool outputs so the catch block can release reservations.
        var validatedToolOutputs: [ToolOutputSubmission] = []
        var repositoryAdmitted = false

        do {
            // 2. Validate thread existence before any preparation proceeds.
            try await dependencies.threadManager.ensureThreadExists(id: threadID)

            // The cohesive repository owns the durable admission barrier when supplied. The
            // legacy process-local gate remains only for configurations that have not opted into
            // the v4 repository yet.
            if let runtimeRepository = dependencies.runtimeRepository {
                let fingerprint = Self.callerIntentFingerprint(
                    messageContent: messageContent,
                    tools: tools,
                    toolOutputs: toolOutputs,
                    systemInstructions: systemInstructions,
                    agentId: agentId,
                    maxModelRounds: maxModelRounds,
                    generationParameters: generationParameters,
                    structuredOutput: structuredOutput,
                    sidecars: sidecars,
                    sidecarCommitPolicy: sidecarCommitPolicy,
                    includeSidecarMechanismPreamble: includeSidecarMechanismPreamble,
                    responseModalities: responseModalities,
                    audioOutput: audioOutput
                )
                let admission = try await dependencies.threadAuthorityCoordinator.withThread(threadID) {
                    try await runtimeRepository.admitTurn(
                        threadID: threadID,
                        requestID: requestId,
                        callerIntentFingerprint: fingerprint,
                        turnID: turnID,
                        now: Date()
                    )
                }
                switch admission.disposition {
                case .admitted:
                    repositoryAdmitted = true
                case .joined, .replayed:
                    // The repository owns the existing execution. Return its durable record to
                    // the caller rather than starting a second provider/tool side effect.
                    return .existing(admission)
                }
            } else {
                guard await TurnIdempotencyGate.shared.checkAndMark(requestId: requestId) else {
                    throw TurnEngineError.duplicateRequestID(requestId)
                }
            }

            // 3. Validate tool output submissions and reserve pending call IDs — no persistence.
            //    Already-persisted outputs are skipped (resumable batch support).
            validatedToolOutputs = try await ExternalToolOutputSubmissionGate.shared.validate(
                toolOutputs ?? [],
                threadID: threadID,
                messageStore: dependencies.messageStore
            )

            // 4. Load existing thread history (before new inputs are persisted).
            let threadMessages = try await dependencies.messageStore.fetchMessages(for: threadID)
            var history = threadMessages.map { $0.toMessage() }
            let currentRemoteDepth = threadMessages.map(\.remoteDepth).max() ?? 0

            // 5. Build an in-memory augmented history that includes the new tool outputs and
            //    user message, so validation, context gathering, and prompt assembly see the
            //    same history they would after persistence — without actually persisting yet.
            for output in validatedToolOutputs {
                history.append(Message(content: output.output, role: .tool, toolCallID: output.toolCallID))
            }
            if hasMessage {
                history.append(Message(content: messageContent, role: .user))
            }

            // 6. Validate the augmented tool-call history.
            try validateToolHistory(history)

            // 7. Load context
            let contextResult = try await fetchContext(
                turnBriefingBuilder: turnBriefingBuilder,
                message: messageContent.text,
                history: history,
                pipeline: contextPipeline
            )
            var turnDiagnostics = contextResult.diagnostics
            let contextData = contextResult.data

            // 8. Resolve workspaces and session entities
            let workspaceResult = try await dependencies.threadManager.getWorkspaces(for: threadID)
            turnDiagnostics += workspaceResult.degradations.map {
                TurnDiagnostic(
                    dependency: .workspace,
                    operation: $0.operation,
                    entityID: $0.entityID,
                    errorIdentity: $0.errorIdentity,
                    message: $0.message
                )
            }
            turnDiagnostics += await dependencies.threadManager.consumeDegradations(for: threadID)
            try enforceRequired(turnDiagnostics)
            await dependencies.threadManager.touchThread(id: threadID)
            let thread = await dependencies.threadManager.thread(id: threadID)
            turnDiagnostics += agentDiagnostics

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
            let extensionSections = await dependencies.threadManager.gatherExtensionSections(
                threadID: threadID,
                agentID: agent?.id,
                message: messageContent.text
            )

            let promptRequest = LLMPromptRequest(
                userContent: messageContent,
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

            let promptHistory = await dependencies.promptHistoryRegistry.history(for: threadID)
            let structuredDiff = await promptHistory.structuredDiffHint()
            let providerConfig = await dependencies.llmService.configuration.activeProviderConfiguration
            let budget = try TurnEngine.makeTokenBudget(
                contextWindowTokens: providerConfig.contextWindowTokens,
                maxOutputTokens: generationParameters?.maxTokens
            )

            let renderedPrompt = try await PromptAssembler.assemble(
                promptRequest,
                agent: agent,
                thread: thread,
                extensionSections: extensionSections,
                options: PromptAssemblyOptions(
                    tokenBudget: budget,
                    logger: assemblyLogger,
                    structuredDiff: structuredDiff
                )
            )

            // 10. Reuse the final rendered artifact for messages + prompt history
            var initialMessages = renderedPrompt.buildMessages()
            let resolvedSections = renderedPrompt.sections

            // 11. Record prompt snapshot for cache tracking BEFORE committing inputs. This is the
            //     remaining fallible preparation step; keeping it ahead of persistence avoids
            //     orphaning a user/tool input when the journal rejects the transition.
            let update: PromptHistoryUpdate
            do {
                update = try await promptHistory.update(prompt: renderedPrompt)
            } catch {
                logger.error("Prompt history update failed; aborting turn before returning context", metadata: [
                    LogKeys.threadID: .string(threadID.uuidString),
                    LogKeys.requestID: .string(requestId.uuidString),
                    "error": .string(String(describing: error)),
                ])
                throw TurnEngineError.promptHistoryInconsistent(String(describing: error))
            }
            guard let diff = update.diff else {
                logger.error("Prompt history update produced no diff; aborting turn", metadata: [
                    LogKeys.threadID: .string(threadID.uuidString),
                    LogKeys.requestID: .string(requestId.uuidString),
                    "journalState": .string("update_without_diff"),
                ])
                throw TurnEngineError.promptHistoryInconsistent("update produced no prompt diff")
            }
            logger.debug(
                "Prompt journal updated: added=\(diff.added.count) removed=\(diff.removed.count) changed=\(diff.changed.count)",
                metadata: [
                    LogKeys.threadID: .string(threadID.uuidString),
                    LogKeys.requestID: .string(requestId.uuidString),
                    LogKeys.modelRoundIndex: .string("0"),
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
                initialMessages = try initialMessages.map { message in
                    guard message.role == .assistant else { return message }
                    let projectedText = message.messageContent.text
                    let parts = try message.messageContent.parts.flatMap { part -> [MessageContentPart] in
                        guard case let .audio(audio) = part else { return [part] }
                        guard let transcript = audio.transcript, !transcript.isEmpty else {
                            throw MultimodalContentError.missingAudioTranscript
                        }
                        return projectedText.contains(transcript) ? [] : [.text(transcript)]
                    }
                    return LLMMessage(
                        role: message.role,
                        content: MessageContent(parts: parts),
                        name: message.name,
                        toolCallID: message.toolCallID,
                        toolCalls: message.toolCalls,
                        reasoning: message.reasoning
                    )
                }
            }

            // 12. Commit persistence after all fallible preparation succeeds. Tool outputs are
            //     committed first (resumable batch), then the user message. The user row uses the
            //     request ID as its existing message identity, so a later preparation failure can
            //     retry without inserting the same input twice.
            try await ExternalToolOutputSubmissionGate.shared.commit(
                validatedToolOutputs,
                threadID: threadID,
                messageStore: dependencies.messageStore
            )
            if hasMessage {
                let userMsg = ThreadMessage(
                    id: requestId,
                    threadID: threadID,
                    role: .user,
                    content: messageContent
                )
                try await dependencies.messageStore.saveMessageIfAbsent(
                    userMsg,
                    idempotencyKey: requestId
                )
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
                            nodeID: $0.nodeID,
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

            return .ready(TurnContext(
                threadID: threadID,
                turnID: turnID,
                requestId: requestId,
                agentId: agentId,
                modelName: modelName,
                maxModelRounds: maxModelRounds,
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
                modelRoundIndex: 0,
                responseModalities: responseModalities,
                audioOutput: audioOutput,
                outputs: TurnOutputs()
            ))
        } catch {
            if let runtimeRepository = dependencies.runtimeRepository, repositoryAdmitted {
                _ = try? await runtimeRepository.failTurn(
                    turnID: turnID,
                    message: "Turn preparation failed before execution.",
                    now: Date()
                )
            } else {
                // Release the idempotency marker so the caller can retry with the same requestId.
                await TurnIdempotencyGate.shared.release(requestId: requestId)
            }
            // Release any tool-output reservations made during validation.
            await ExternalToolOutputSubmissionGate.shared.releaseReservations(
                threadID: threadID,
                toolCallIds: validatedToolOutputs.map(\.toolCallID)
            )
            throw error
        }
    }

    private static func callerIntentFingerprint(
        messageContent: MessageContent,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]?,
        systemInstructions: String?,
        agentId: UUID?,
        maxModelRounds: Int,
        generationParameters: GenerationParameters?,
        structuredOutput: StructuredOutputRequest?,
        sidecars: [SidecarDirective],
        sidecarCommitPolicy: SidecarCommitPolicy,
        includeSidecarMechanismPreamble: Bool,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) -> String {
        let toolIntent = tools.map { tool in
            [
                tool.callName,
                tool.name,
                tool.description,
                tool.usageExample ?? "",
                String(tool.requiresPermission),
                String(describing: tool.sideEffects),
                canonicalFingerprint(tool.toolReference),
                canonicalFingerprint(tool.origin),
                canonicalFingerprint(tool.parametersSchema),
            ].joined(separator: "\u{1E}")
        }.joined(separator: "\u{1F}")
        return [
            canonicalFingerprint(messageContent),
            toolIntent,
            canonicalFingerprint(toolOutputs),
            systemInstructions ?? "",
            agentId?.uuidString ?? "",
            "\(maxModelRounds)",
            canonicalFingerprint(generationParameters),
            canonicalFingerprint(structuredOutput),
            canonicalFingerprint(sidecars),
            canonicalFingerprint(sidecarCommitPolicy),
            String(includeSidecarMechanismPreamble),
            canonicalFingerprint(responseModalities.map(\.rawValue).sorted()),
            canonicalFingerprint(audioOutput),
        ].joined(separator: "\u{1F}")
    }

    private static func canonicalFingerprint<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return String(describing: value) }
        return data.base64EncodedString()
    }

    func validateMultimodalRequest(
        content: MessageContent,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?,
        capabilities: Set<ModelCapability>,
        provider: LLMProvider
    ) throws {
        if content.parts.contains(where: { if case .image = $0 { return true }; return false }),
           !capabilities.contains(.imageInput)
        {
            throw MultimodalContentError.missingCapability(.imageInput)
        }
        if content.parts.contains(where: { if case .audio = $0 { return true }; return false }),
           !capabilities.contains(.audioInput)
        {
            throw MultimodalContentError.missingCapability(.audioInput)
        }
        if responseModalities.contains(.audio) {
            guard capabilities.contains(.audioOutput) else {
                throw MultimodalContentError.missingCapability(.audioOutput)
            }
            guard audioOutput != nil else { throw MultimodalContentError.missingAudioOutputOptions }
        } else if audioOutput != nil {
            throw MultimodalContentError.audioOptionsWithoutAudioModality
        }

        if let audioOutput, audioOutput.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MultimodalContentError.missingAudioOutputOptions
        }

        switch provider {
        case .anthropic:
            let supportedImageTypes = ["image/jpeg", "image/png", "image/gif", "image/webp"]
            for part in content.parts {
                guard case let .image(image) = part else { continue }
                guard supportedImageTypes.contains(image.mediaType.lowercased()) else {
                    throw MultimodalContentError.invalidImageMediaType(image.mediaType)
                }
            }
            if content.parts.contains(where: { if case .audio = $0 { return true }; return false }) {
                throw MultimodalContentError.missingCapability(.audioInput)
            }
            if responseModalities.contains(.audio) {
                throw MultimodalContentError.missingCapability(.audioOutput)
            }
        case .ollama:
            let containsImages = content.parts.contains { if case .image = $0 { return true }; return false }
            let containsText = content.parts.contains { if case .text = $0 { return true }; return false }
            if containsImages, containsText {
                throw MultimodalContentError.unsupportedContentLayout(provider: .ollama)
            }
            if content.parts.contains(where: { if case .audio = $0 { return true }; return false }) {
                throw MultimodalContentError.missingCapability(.audioInput)
            }
            if responseModalities.contains(.audio) {
                throw MultimodalContentError.missingCapability(.audioOutput)
            }
        case .openAI, .openAICompatible, .openRouter:
            for part in content.parts {
                guard case let .audio(audio) = part else { continue }
                guard audio.format == .wav || audio.format == .mp3 else {
                    throw MultimodalContentError.unsupportedAudioFormat(audio.format, provider: provider)
                }
            }
        }
    }
}

// MARK: - Preparation Steps

private extension TurnEngine {
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
                tagGenerator: { [utilityClient = dependencies.utilityClient] query in await utilityClient.bestEffortTags(for: query) },
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
            entityID: "turn",
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
            entityID: entityId,
            errorIdentity: TurnEvent.ErrorIdentity.extracting(from: error),
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
                      // thread unusable. Store outages and resolver failures remain fatal.
                      return diagnostic.errorIdentity?.code != 3004
                  case .origin:
                      return false
                  }
              })
        else { return }
        throw TurnDegradationError.required(
            diagnostic,
            NSError(domain: diagnostic.errorIdentity?.domain ?? PKErrorDomain.turn, code: diagnostic.errorIdentity?.code ?? 9010)
        )
    }

    func validateToolHistory(_ history: [Message]) throws {
        var pendingToolCallIds = Set<String>()

        for message in history {
            switch message.role {
            case .assistant:
                let toolCalls = message.toolCalls ?? []
                if !pendingToolCallIds.isEmpty {
                    throw TurnEngineError.danglingToolCall(id: pendingToolCallIds.min() ?? toolCalls.first?.id ?? "<unknown>")
                }
                if !toolCalls.isEmpty {
                    pendingToolCallIds = Set(toolCalls.map(\.id))
                }
            case .tool:
                guard let toolCallID = message.toolCallID else {
                    throw TurnEngineError.danglingToolResult(id: "<missing>")
                }
                guard pendingToolCallIds.remove(toolCallID) != nil else {
                    throw TurnEngineError.danglingToolResult(id: toolCallID)
                }
            case .user, .system, .summary:
                if !pendingToolCallIds.isEmpty {
                    throw TurnEngineError.danglingToolCall(id: pendingToolCallIds.min() ?? "<unknown>")
                }
            }
        }

        guard pendingToolCallIds.isEmpty else {
            throw TurnEngineError.danglingToolCall(id: pendingToolCallIds.min() ?? "<unknown>")
        }
    }
}
