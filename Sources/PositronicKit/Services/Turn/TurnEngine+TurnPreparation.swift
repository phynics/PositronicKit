import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

// MARK: - Turn Preparation

extension TurnEngine {
    private struct ExecutionAuthority: Sendable {
        let thread: Thread
        let agent: Agent?
    }

    /// The bounded input to Turn admission. Prompt assembly and Model Round configuration remain
    /// local to `prepareSession`; admission only needs durable identity, authority, and input.
    struct TurnAdmissionRequest: Sendable {
        let threadID: UUID
        let turnID: UUID
        let requestID: UUID
        let inputMessage: ThreadMessage?
        let executionKind: TurnExecutionKind
        let agentID: UUID?
        let callerIntentFingerprint: String
    }

    struct TurnAdmissionResult: Sendable {
        enum Disposition: Sendable {
            case admitted
            case existing(TurnAdmission)
        }

        let disposition: Disposition
        let agent: Agent?
        let agentContext: AgentContextSnapshot?
        let workspaceToolCatalog: WorkspaceToolCatalog
    }

    private struct TurnPreparationRecoveryError: Error, Sendable, CustomStringConvertible {
        let turnID: UUID
        let failure: String
        let recoveryFailure: String

        var description: String {
            "Unable to durably compensate preparation failure for Turn \(turnID): "
                + "failTurn failed (\(failure)); force interrupt failed (\(recoveryFailure))."
        }
    }

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
        switch instance.lifecycle {
        case .active:
            break
        case .retiring:
            throw AgentError.agentRetiring(agentId)
        case .retired:
            throw AgentError.agentRetired(agentId)
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
            throw TurnError.managedExecutionAgentMismatch(
                threadID: threadID,
                requestedAgentID: agentId,
                attachedAgentID: thread.attachedAgentID
            )
        }

        return AgentPreflight(instance: instance, diagnostics: [])
    }

    /// Consolidates all pre-turn logic: saving inputs, resolving entities,
    /// and building the initial prompt.
    ///
    /// The runtime repository commits the user message with Turn admission so an admitted Turn
    /// can never be observed without its input. Repeated requests join or replay the durable Turn
    /// rather than re-executing provider or tool side effects.
    func prepareSession(
        _ executionRequest: TurnExecutionRequest,
        turnID: UUID,
        agent: Agent?,
        agentContext: AgentContextSnapshot? = nil,
        agentDiagnostics: [TurnDiagnostic],
        onAdmission: (@Sendable () async -> Void)? = nil
    ) async throws -> PreparedSession {
        let request = executionRequest.request
        let threadID = request.threadID
        let requestId = executionRequest.requestID
        let messageContent = request.messageContent
        let tools = request.tools
        let toolOutputs = request.toolOutputs
        let systemInstructions = request.systemInstructions
        let agentId = executionRequest.context.agentID
        let executionKind = executionRequest.context.kind
        let contributors = executionRequest.context.contributors
        let maxModelRounds = request.maxModelRounds
        let generationParameters = executionRequest.generationParameters
        let structuredOutput = request.structuredOutput
        let sidecars = request.sidecars
        let sidecarCommitPolicy = request.sidecarCommitPolicy
        let includeSidecarMechanismPreamble = request.includeSidecarMechanismPreamble
        let assemblyLogger = request.promptAssemblyLogger
        let responseModalities = request.responseModalities
        let audioOutput = request.audioOutput

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

        // `call_tool` is owned by the workspace catalog and must never be caller-defined. This is
        // pure request validation, so reject it before any admission side effect.
        guard !tools.contains(where: { $0.callName == "call_tool" }) else {
            throw ToolError.reservedToolName("call_tool")
        }

        // Track validated tool outputs so the catch block can release reservations.
        var validatedToolOutputs: [ToolOutputSubmission] = []
        var repositoryAdmitted = false
        let inputMessage = hasMessage
            ? ThreadMessage(
                id: requestId,
                threadID: threadID,
                role: .user,
                content: messageContent
            )
            : nil
        var resolvedAgent = agent
        var resolvedAgentContext = agentContext
        var resolvedWorkspaceToolCatalog: WorkspaceToolCatalog?
        var resolvedContributions: [TurnContextContribution] = []
        let admissionRequest = TurnAdmissionRequest(
            threadID: threadID,
            turnID: turnID,
            requestID: requestId,
            inputMessage: inputMessage,
            executionKind: executionKind,
            agentID: agentId,
            callerIntentFingerprint: executionRequest.callerIntentFingerprint
        )

        do {
            // 2. Validate thread existence before any preparation proceeds.
            try await dependencies.threadManager.ensureThreadExists(id: threadID)

            let admissionResult = try await admitTurn(admissionRequest)
            resolvedAgent = admissionResult.agent ?? resolvedAgent
            resolvedAgentContext = admissionResult.agentContext ?? resolvedAgentContext
            resolvedWorkspaceToolCatalog = admissionResult.workspaceToolCatalog
            switch admissionResult.disposition {
            case .admitted:
                repositoryAdmitted = true
                // Publish admission before the remaining preparation work. Joiners for the
                // same idempotent request can now subscribe to future events instead of
                // falling back to terminal-only replay while prompt/workspace preparation
                // is still in progress.
                await onAdmission?()
            case let .existing(admission):
                // The repository owns the existing execution. Return its durable record to the
                // caller rather than starting a second provider/tool side effect.
                return .existing(admission)
            }

            if let turnContextSource = dependencies.turnContextSource {
                let request = TurnContextRequest(
                    threadID: threadID,
                    turnID: turnID,
                    requestID: requestId,
                    agentID: agentId,
                    executionKind: executionKind,
                    message: messageContent.text,
                    contributors: contributors
                )
                do {
                    let contributions = try await turnContextSource.contributions(for: request)
                    try validateTurnContextContributions(contributions)
                    resolvedContributions = contributions
                } catch {
                    let diagnostic = diagnostic(
                        for: .context,
                        operation: "turnContextContributions",
                        entityId: turnID.uuidString,
                        error: error
                    )
                    let sourceRequiresContext = turnContextSource.failureRequirement == .required
                    if sourceRequiresContext {
                        throw TurnDegradationError.required(diagnostic, error)
                    }
                    await appendCustomizationNotice(
                        code: .contextContributionFailed,
                        turnID: turnID,
                        message: diagnostic.message
                    )
                }
            }

            let effectiveTools: [AnyTool]
            if let catalog = resolvedWorkspaceToolCatalog, !catalog.isEmpty {
                let directToolNames = Set(catalog.directTools.map(\.callName))
                effectiveTools = catalog.directTools
                    + tools.filter { !directToolNames.contains($0.callName) }
                    + [catalog.callTool]
            } else {
                effectiveTools = tools
            }

            // 3. Validate tool output submissions and reserve pending call IDs — no persistence.
            //    Already-persisted outputs are skipped (resumable batch support).
            validatedToolOutputs = try await ExternalToolOutputSubmissionGate.shared.validate(
                toolOutputs ?? [],
                threadID: threadID,
                inputMessageID: inputMessage?.id,
                runtimeRepository: dependencies.runtimeRepository
            )

            // 4. Load existing thread history, including the input committed at admission.
            let threadMessages = try await dependencies.runtimeRepository.fetchMessages(for: threadID)
            // The repository commits the current input before preparation, while external tool
            // outputs are committed later. Project the request-local input after those outputs
            // for prompt validation: provider history must keep an assistant tool call adjacent
            // to its tool result even though durable append order is input-before-output.
            var history = threadMessages
                .filter { $0.id != inputMessage?.id }
                .map { $0.toMessage() }
            let currentRemoteDepth = threadMessages.map(\.remoteDepth).max() ?? 0

            // 5. Build an in-memory augmented history that includes new tool outputs.
            for output in validatedToolOutputs {
                history.append(Message(content: output.output, role: .tool, toolCallID: output.toolCallID))
            }

            // Validate the augmented tool-call history, including the just-admitted input. The
            // input remains the prompt's explicit UserQuery so sidecar instructions and the user
            // text stay in one final user message instead of being split across history.
            var validationHistory = history
            if let inputMessage {
                validationHistory.append(inputMessage.toMessage())
            }
            try validateToolHistory(validationHistory)

            // 7. Resolve preparation diagnostics. Agent context and bounded Turn contributions
            // were captured before this point and are rendered directly into the prompt.
            var turnDiagnostics: [TurnDiagnostic] = []
            turnDiagnostics += resolvedAgentContext?.diagnostics ?? []

            // 8. Resolve session entities. Direct Turns deliberately do not inherit an Agent's
            // primary workspace or memory; ordinary Workspace bindings belong to the Thread and
            // are captured above for both execution paths. Direct contributors remain the
            // explicit caller-owned selection captured on `TurnContext`.
            let workspaceResult: WorkspaceQueryResult
            if let catalog = resolvedWorkspaceToolCatalog {
                workspaceResult = WorkspaceQueryResult(
                    primary: catalog.entries.first(where: \.isPrimary)?.workspace,
                    attached: catalog.entries.filter { !$0.isPrimary }.map(\.workspace)
                )
            } else {
                workspaceResult = try await dependencies.threadManager.getWorkspaces(for: threadID)
            }
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
            let promptRequest = LLMPromptRequest(
                userContent: messageContent,
                turnInstructions: sidecarTurnInstructions,
                contextContributions: resolvedContributions,
                chatHistory: history,
                tools: effectiveTools,
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
                agent: resolvedAgent,
                agentContext: resolvedAgentContext,
                thread: thread,
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

            // 12. Commit external tool outputs after all fallible preparation succeeds. The
            //     repository already committed the user message atomically with Turn admission.
            try await ExternalToolOutputSubmissionGate.shared.commit(
                validatedToolOutputs,
                threadID: threadID,
                runtimeRepository: dependencies.runtimeRepository
            )

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
                agentPrivateThreadID: resolvedAgent?.privateThreadID,
                agentContext: resolvedAgentContext,
                contextContributions: resolvedContributions,
                executionKind: executionKind,
                contributors: contributors,
                modelName: modelName,
                maxModelRounds: maxModelRounds,
                systemInstructions: effectiveSystemInstructions,
                availableTools: effectiveTools,
                workspaceToolCatalog: resolvedWorkspaceToolCatalog,
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
        } catch let preparationError {
            var recoveryError: Error?
            if repositoryAdmitted {
                recoveryError = await compensatePreparationFailure(
                    repository: dependencies.runtimeRepository,
                    turnID: turnID,
                    preparationError: preparationError
                )
                await dependencies.eventHub.finish(
                    turnID: turnID,
                    error: recoveryError ?? preparationError
                )
            }
            // Release any tool-output reservations made during validation.
            await ExternalToolOutputSubmissionGate.shared.releaseReservations(
                threadID: threadID,
                toolCallIds: validatedToolOutputs.map(\.toolCallID)
            )
            if let recoveryError {
                throw recoveryError
            }
            throw preparationError
        }
    }

    /// Captures all authority-bearing state and then crosses the repository's atomic admission
    /// barrier.
    func admitTurn(_ request: TurnAdmissionRequest) async throws -> TurnAdmissionResult {
        try await withAdmissionAuthority(threadID: request.threadID, agentID: request.agentID) { [self] in
            // Revalidate the execution authority in the same per-Thread lane as admission. The
            // handle's initial lookup is only a convenience preflight; an attachment can change
            // while preparation is waiting on provider or persistence work.
            let authority = try await validateExecutionAuthority(
                threadID: request.threadID,
                executionKind: request.executionKind,
                agentID: request.agentID
            )
            var context: AgentContextSnapshot?
            if let currentAgent = authority.agent {
                let snapshot = try await dependencies.agentContextSource.snapshot(
                    for: currentAgent,
                    thread: authority.thread
                )
                guard snapshot.identity.agentID == currentAgent.id else {
                    throw AgentContextError.identityMismatch(
                        expected: currentAgent.id,
                        actual: snapshot.identity.agentID
                    )
                }
                context = snapshot
            }
            let workspaceCatalog = try await dependencies.threadManager.captureWorkspaceToolCatalog(
                for: request.threadID,
                primaryWorkspaceID: authority.agent?.primaryWorkspaceID
            )

            let admission = try await dependencies.runtimeRepository.admitTurn(
                threadID: request.threadID,
                requestID: request.requestID,
                callerIntentFingerprint: request.callerIntentFingerprint,
                inputMessage: request.inputMessage,
                executionKind: request.executionKind,
                capturedAgentID: authority.agent?.id,
                turnID: request.turnID,
                now: Date()
            )
            switch admission.disposition {
            case .admitted:
                return TurnAdmissionResult(
                    disposition: .admitted,
                    agent: authority.agent,
                    agentContext: context,
                    workspaceToolCatalog: workspaceCatalog
                )
            case .joined, .replayed:
                return TurnAdmissionResult(
                    disposition: .existing(admission),
                    agent: authority.agent,
                    agentContext: context,
                    workspaceToolCatalog: workspaceCatalog
                )
            }
        }
    }

    private func validateExecutionAuthority(
        threadID: UUID,
        executionKind: TurnExecutionKind,
        agentID: UUID?
    ) async throws -> ExecutionAuthority {
        guard let thread = try await dependencies.threadManager.threadStore.fetchThread(id: threadID) else {
            throw ThreadError.threadNotFound
        }
        switch executionKind {
        case .agentManaged:
            // A nil Agent is retained for the legacy internal `run` seam. Public managed
            // admission supplies the captured identity; when present it must still match the
            // durable attachment immediately before admission.
            if let agentID, thread.attachedAgentID != agentID {
                throw TurnError.managedExecutionAgentMismatch(
                    threadID: threadID,
                    requestedAgentID: agentID,
                    attachedAgentID: thread.attachedAgentID
                )
            }
            guard let agentID else {
                return ExecutionAuthority(thread: thread, agent: nil)
            }
            guard let agent = try await dependencies.agentStore.fetchAgent(id: agentID) else {
                throw AgentError.agentNotFound(agentID)
            }
            switch agent.lifecycle {
            case .active:
                return ExecutionAuthority(thread: thread, agent: agent)
            case .retiring:
                throw AgentError.agentRetiring(agentID)
            case .retired:
                throw AgentError.agentRetired(agentID)
            }
        case .direct:
            guard thread.attachedAgentID == nil else {
                throw TurnError.directExecutionRequiresDetachedThread(threadID)
            }
            return ExecutionAuthority(thread: thread, agent: nil)
        }
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
    private func compensatePreparationFailure(
        repository: any ThreadRuntimeRepository,
        turnID: UUID,
        preparationError: Error
    ) async -> TurnPreparationRecoveryError? {
        do {
            _ = try await repository.failTurn(
                turnID: turnID,
                message: "Turn preparation failed before execution.",
                now: Date()
            )
            return nil
        } catch let failure {
            logger.error("Unable to record failed Turn preparation for \(turnID): \(failure)", metadata: [
                LogKeys.turnID: .string(turnID.uuidString),
                "preparationError": .string(String(describing: preparationError)),
            ])
            do {
                _ = try await repository.interruptTurn(
                    turnID: turnID,
                    reason: "Turn preparation compensation failed: \(failure)",
                    force: true,
                    now: Date()
                )
                logger.error("Force-interrupted Turn \(turnID) after failed preparation compensation", metadata: [
                    LogKeys.turnID: .string(turnID.uuidString),
                    "failure": .string(String(describing: failure)),
                ])
                return nil
            } catch let recoveryFailure {
                let recoveryError = TurnPreparationRecoveryError(
                    turnID: turnID,
                    failure: String(describing: failure),
                    recoveryFailure: String(describing: recoveryFailure)
                )
                logger.error(Logger.Message(stringLiteral: recoveryError.description), metadata: [
                    LogKeys.turnID: .string(turnID.uuidString),
                    "preparationError": .string(String(describing: preparationError)),
                ])
                return recoveryError
            }
        }
    }

    /// Serializes managed admission with Agent lifecycle/identity mutations. Direct turns have
    /// no Agent authority and therefore only use their per-Thread lane.
    func withAdmissionAuthority<T: Sendable>(
        threadID: UUID,
        agentID: UUID?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if let agentID {
            return try await dependencies.agentAuthorityCoordinator.withAgent(agentID) {
                try await dependencies.threadAuthorityCoordinator.withThread(
                    threadID,
                    operation: operation
                )
            }
        }
        return try await dependencies.threadAuthorityCoordinator.withThread(
            threadID,
            operation: operation
        )
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
                      // The default filesystem Agent source treats an absent SOUL or Notes
                      // catalog as an observable degradation: identity-only execution remains
                      // valid, and the diagnostic is carried on the Turn for host inspection.
                      return !["readSoul", "catalogNotes"].contains(diagnostic.operation)
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

    func validateTurnContextContributions(_ contributions: [TurnContextContribution]) throws {
        var seenIDs = Set<UUID>()
        var seenKeys = Set<String>()
        for contribution in contributions {
            guard seenIDs.insert(contribution.id).inserted else {
                throw TurnContextContributionError.invalidKey(contribution.id.uuidString)
            }
            let key = "\(contribution.namespace).\(contribution.key)"
            guard seenKeys.insert(key).inserted else {
                throw TurnContextContributionError.invalidKey(key)
            }
        }
    }

}
