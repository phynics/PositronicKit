import Foundation
import Logging
import PKContracts
import PKUtilities

/// Immutable, `Sendable` inputs for building one assistant `TimelineMessage` row.
///
/// The success path builds this from live `TurnContext` outputs and persists the row in the
/// pipeline. The terminal finalizer captures it at hand-off for a cancelled or failed Turn so it
/// can build the partial row after the Timeline is gone (ADR 0010).
struct AssistantRowMaterial: Sendable {
    let timelineID: UUID
    let agentID: UUID?
    let executionKind: TurnExecutionKind
    let content: MessageContent
    let thinking: String
    let toolCallsJSON: String
}

/// Pipeline stage responsible for persisting the assistant message and preparing completion data.
///
/// Prepares the assistant message produced by the LLM turn. The stage:
/// - With `toolCalls` JSON when the LLM requested tool calls (pending execution).
/// - Without `toolCalls` when the response is a plain text reply.
///
/// It also produces the per-model-round ``PromptCacheReport``, emits it as a non-terminal
/// ``TurnEvent``, and persists it as a Turn correlation so outcome joiners and replay see it.
///
/// After this stage, `TurnEngine.runTurnLoop` inspects `context.outputs.toolCallAccumulators` to decide
/// whether to invoke `ToolRouter.handlePendingToolCalls` and continue the loop.
struct MessagePersistenceStage: PipelineStage {
    /// The correlation kind used to persist a round's ``PromptCacheReport`` on its Turn.
    static let promptCacheReportCorrelationKind = "prompt-cache-report"

    let runtimeRepository: any TimelineRuntimeRepository
    let logger: Logger
    let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
    let loggingConfiguration: LoggingConfiguration

    init(
        runtimeRepository: any TimelineRuntimeRepository,
        logger: Logger? = nil,
        diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default
        , loggingConfiguration: LoggingConfiguration = .default
    ) {
        self.runtimeRepository = runtimeRepository
        self.logger = logger ?? Logger.module(named: "message-persistence")
        self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
        self.loggingConfiguration = loggingConfiguration
    }

    func process(_ context: TurnContext) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        let hasPendingToolCalls = await !context.outputs.toolCallAccumulators.isEmpty
        let streamFinishReason = await context.outputs.streamFinishReason

        // Build and record the prompt-cache report before the message so the typed snapshot can
        // link it. The report is independent of the diagnostic-snapshot policy: it is the
        // measurement surface for prompt caching and is redaction-safe by construction.
        let report = await buildPromptCacheReport(from: context)
        logger.debug(
            "Prompt cache report",
            metadata: [
                LogKeys.turnID: .string(context.turnID.uuidString),
                LogKeys.modelRoundIndex: .string("\(context.modelRoundIndex)"),
                "promptCaching": .string(context.promptCaching.isEnabled ? "enabled" : "disabled"),
                "expectedReusableTokens": .string("\(report.expectedReusableTokens)"),
                "reportedCachedTokens": .string("\(report.reportedCachedTokens ?? 0)"),
                "breakpointTiers": .string(report.breakpoints.map(\.tier.rawValue).joined(separator: ",")),
                "resets": .string(report.resets.map(\.rawValue).joined(separator: ",")),
            ]
        )
        await persist(report: report, context: context)

        var assistantMsg = await Self.buildAssistantMessage(
            from: context,
            hasPendingToolCalls: hasPendingToolCalls,
            status: nil,
            logger: logger
        )
        if !hasPendingToolCalls {
            // The terminal assistant row is committed by completeTurn. The terminal coordinator
            // owns the event so it cannot precede that commit.
            if let snapshot = await buildSnapshot(from: context, report: report) {
                assistantMsg.turnSnapshot = snapshot
            }
            await context.outputs.setTerminalAssistantMessage(assistantMsg)
            let streamUsage = await context.outputs.streamUsage
            let turnDuration = await context.outputs.turnDuration
            let tokensPerSecond = await context.outputs.tokensPerSecond
            let fullResponse = await context.outputs.fullResponse
            let metadata = LLMResponse(
                content: fullResponse.isEmpty ? nil : fullResponse,
                model: context.modelName,
                usage: streamUsage,
                finishReason: streamFinishReason,
                duration: turnDuration,
                tokensPerSecond: tokensPerSecond
            )
            await context.outputs.setTerminalCompletionMetadata(metadata)
        } else {
            try await runtimeRepository.recordTurnMessage(assistantMsg, turnID: context.turnID)
            await context.outputs.markAssistantResponseDurable()
        }

        return AsyncThrowingStream { continuation in
            continuation.yield(.promptCacheReport(report))
            continuation.finish()
        }
    }

    // MARK: - Prompt cache report

    /// Builds this model round's ``PromptCacheReport`` and advances the Timeline's fingerprint
    /// state so the next round can compare against it.
    private func buildPromptCacheReport(from context: TurnContext) async -> PromptCacheReport {
        let policy = context.promptCaching
        let breakpoints = LLMStreamingStage.promptCacheDirective(for: context)?.breakpoints ?? []
        let usage = await context.outputs.streamUsage

        let accounting: PromptCacheAccounting
        if let history = context.promptHistory, let renderedPrompt = context.renderedPrompt {
            accounting = await history.accountPromptCache(
                prompt: renderedPrompt,
                historyTrimmed: context.promptCacheHistoryTrimmed,
                cachingEnabled: policy.isEnabled,
                turnID: context.turnID,
                modelRoundIndex: context.modelRoundIndex,
                breakpoints: breakpoints
            )
        } else {
            accounting = PromptCacheResetDetector.account(
                previous: nil,
                current: .empty,
                historyTrimmed: context.promptCacheHistoryTrimmed,
                cachingEnabled: policy.isEnabled
            )
        }

        return PromptCacheReport(
            turnID: context.turnID,
            modelRoundIndex: context.modelRoundIndex,
            policy: policy,
            breakpoints: breakpoints,
            expectedReusableTokens: accounting.expectedReusableTokens,
            reportedCachedTokens: usage?.promptTokensDetails?.cachedTokens,
            reportedCacheWriteTokens: usage?.promptTokensDetails?.cacheWriteTokens,
            resets: accounting.resets
        )
    }

    /// Appends the report to the Turn's durable correlation trail. A store failure is logged but
    /// never fails the generation: the live event already carried the report.
    private func persist(report: PromptCacheReport, context: TurnContext) async {
        guard let data = try? SerializationUtils.jsonEncoder.encode(report),
              let value = String(bytes: data, encoding: .utf8)
        else {
            logger.warning("Unable to encode prompt-cache report for Turn \(context.turnID)")
            return
        }
        do {
            try await runtimeRepository.appendCorrelation(
                turnID: context.turnID,
                correlation: TurnCorrelation(kind: Self.promptCacheReportCorrelationKind, value: value),
                now: Date()
            )
        } catch {
            logger.warning(
                "Unable to persist prompt-cache report for Turn \(context.turnID)",
                metadata: LoggingMetadata.makeMetadata(for: error, correlationID: redactedHash(context.turnID.uuidString))
            )
        }
    }

    private func buildSnapshot(from context: TurnContext, report: PromptCacheReport) async -> TurnSnapshot? {
        switch diagnosticSnapshotConfiguration.policy {
        case .off, .metadataOnly:
            return nil
        case .redacted, .full:
            let snapshot = await buildTurnSnapshot(from: context, report: report)
            return DiagnosticSnapshotEncoder.prepared(
                snapshot,
                policy: diagnosticSnapshotConfiguration.policy,
                maxBytes: diagnosticSnapshotConfiguration.maxBytes
            )
        }
    }

    /// Builds the assistant `TimelineMessage` from accumulated turn outputs.
    ///
    /// Shared between the success path (this stage, `status == nil` → `.complete`) and the
    /// finalizer's failure/cancellation error path (`status == .partial` / `.cancelled`), so a
    /// partial turn is persisted with the *same* shape as a complete one and differs only in the
    /// `status` tag. The success-path output is unchanged: `status` defaults to `nil`, which
    /// encodes away and round-trips as `.complete` (STAB-1).
    static func buildAssistantMessage(
        from context: TurnContext,
        hasPendingToolCalls: Bool,
        status: Message.MessageStatus?,
        logger: Logger
    ) async -> TimelineMessage {
        let material = await assistantRowMaterial(
            from: context,
            hasPendingToolCalls: hasPendingToolCalls,
            logger: logger
        )
        return buildAssistantMessage(from: material, status: status)
    }

    /// Captures the immutable inputs for one assistant row from live Turn outputs.
    ///
    /// The terminal finalizer holds the returned value instead of the live `TurnContext`, so it can
    /// resolve a partial row after the Turn's Timeline has been evicted (ADR 0010).
    static func assistantRowMaterial(
        from context: TurnContext,
        hasPendingToolCalls: Bool,
        logger: Logger
    ) async -> AssistantRowMaterial {
        let toolCallsJSON = await buildToolCallsJSON(
            from: context,
            hasPendingToolCalls: hasPendingToolCalls,
            logger: logger
        )
        return AssistantRowMaterial(
            timelineID: context.timelineID,
            agentID: context.agentId,
            executionKind: context.executionKind,
            content: await context.outputs.assistantContent,
            thinking: await context.outputs.fullThinking,
            toolCallsJSON: toolCallsJSON
        )
    }

    /// Builds an assistant `TimelineMessage` from captured, `Sendable` material.
    static func buildAssistantMessage(
        from material: AssistantRowMaterial,
        status: Message.MessageStatus?
    ) -> TimelineMessage {
        TimelineMessage(
            timelineID: material.timelineID,
            role: .assistant,
            content: material.content,
            reasoning: material.thinking.isEmpty ? nil : material.thinking,
            toolCalls: material.toolCallsJSON,
            agentID: material.agentID,
            executionKind: material.executionKind,
            status: status
        )
    }

    private static func buildToolCallsJSON(
        from context: TurnContext,
        hasPendingToolCalls: Bool,
        logger: Logger
    ) async -> String {
        guard hasPendingToolCalls else { return "[]" }
        let sortedCalls = await context.outputs.toolCallAccumulators.sorted(by: { $0.key < $1.key })
        let callsForDB = sortedCalls.compactMap { _, value -> ToolCall? in
            let argsData = value.args.data(using: .utf8) ?? Data()
            // Previously this was a silent `try? ... ?? [:]` that persisted an empty-args tool call
            // on malformed JSON with no trace. We now log a warning so malformed args are
            // diagnosable in the field, while preserving the existing empty-args fallback (the
            // stored shape — `[String: AnyCodable]` — is unchanged; persisting the raw argument
            // string instead would require reshaping `ToolCall.arguments`, which the ticket scopes
            // out). See STAB-12.
            let args: [String: AnyCodable]
            do {
                args = try SerializationUtils.jsonDecoder.decode([String: AnyCodable].self, from: argsData)
            } catch {
                logger.warning(
                    "Persisting malformed tool call with empty arguments",
                    metadata: LoggingMetadata.makeMetadata(for: error, correlationID: redactedHash(value.callId))
                )
                args = [:]
            }
            // Preserve the provider's tool-call id so the persisted assistant tool_call pairs
            // with its tool-result message on later turns (YAK-26).
            return ToolCall(id: value.callId, name: value.name, arguments: args)
        }
        return (try? SerializationUtils.jsonEncoder.encode(callsForDB))
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
    }

    private func buildTurnSnapshot(from context: TurnContext, report: PromptCacheReport) async -> TurnSnapshot {
        let durableTools = await durableToolRecords(for: context)
        let fullResponse = await context.outputs.fullResponse
        let fullThinking = await context.outputs.fullThinking
        let audioData = await context.outputs.audioData
        let audioFormat = await context.outputs.audioFormat
        let audioTranscript = await context.outputs.audioTranscript
        let turnDuration = await context.outputs.turnDuration
        let tokensPerSecond = await context.outputs.tokensPerSecond
        let streamUsage = await context.outputs.streamUsage

        let promptMessages = context.currentMessages.map { param -> TurnContextSnapshot.PromptMessage in
            let (role, content) = Self.extractRoleAndContent(from: param)
            return TurnContextSnapshot.PromptMessage(
                role: role,
                content: content,
                tokenCount: TokenEstimator.estimate(text: content)
            )
        }

        let contextSnapshot = TurnContextSnapshot(promptMessages: promptMessages)

        return TurnSnapshot(
            timelineID: context.timelineID,
            agentID: context.agentId,
            modelName: context.modelName,
            modelRoundIndex: context.modelRoundIndex,
            maxModelRounds: context.maxModelRounds,
            systemInstructions: context.systemInstructions,
            contextSnapshot: contextSnapshot,
            availableToolIDs: context.availableTools.map { $0.callName },
            fullResponse: fullResponse,
            fullThinking: fullThinking,
            audioOutput: audioFormat.map {
                AudioOutputSnapshot(format: $0, byteCount: audioData.count, transcript: audioTranscript)
            },
            toolCalls: durableTools.calls,
            toolResults: durableTools.results,
            turnDuration: turnDuration,
            tokensPerSecond: tokensPerSecond,
            usage: streamUsage,
            promptCacheReport: report
        )
    }

    private func durableToolRecords(
        for context: TurnContext
    ) async -> (calls: [ToolCallRecord], results: [ToolResultRecord]) {
        guard let intents = try? await runtimeRepository.fetchToolIntents(turnID: context.turnID) else {
            return ([], [])
        }
        let results = (try? await runtimeRepository.fetchToolResults(turnID: context.turnID)) ?? []
        let calls = intents.map { ToolCallRecord(name: $0.name, arguments: $0.arguments, turn: $0.modelRoundIndex) }
        let resultRecords = results.map { result in
            let intent = intents.first(where: { $0.toolCallID == result.toolCallID })
            return ToolResultRecord(
                toolCallID: result.toolCallID,
                name: intent?.name ?? "(unknown)",
                output: result.output,
                turn: intent?.modelRoundIndex ?? context.modelRoundIndex
            )
        }
        return (calls, resultRecords)
    }

    // MARK: - Message Extraction

    private static func extractRoleAndContent(
        from param: LLMMessage
    ) -> (role: String, content: String) {
        (param.role.rawValue, param.content)
    }
}

enum DiagnosticSnapshotEncoder {
    /// Returns a redacted/truncated snapshot that fits `maxBytes` when encoded, or `nil` when no
    /// bounded form fits.
    static func prepared(
        _ snapshot: TurnSnapshot,
        policy: DiagnosticSnapshotPolicy,
        maxBytes: Int
    ) -> TurnSnapshot? {
        guard maxBytes > 0 else { return nil }
        let initialLimit = policy == .redacted ? 512 : Int.max
        var limit = initialLimit

        while limit >= 0 {
            let candidate = sanitized(snapshot, maxStringLength: limit)
            if let data = try? SerializationUtils.jsonEncoder.encode(candidate), data.count <= maxBytes {
                return candidate
            }
            if limit == 0 { break }
            limit = limit == Int.max ? 16_384 : limit / 2
        }
        return nil
    }

    private static func sanitized(_ snapshot: TurnSnapshot, maxStringLength: Int) -> TurnSnapshot {
        func clean(_ value: String) -> String {
            let redacted = redactSecrets(value)
            guard redacted.count > maxStringLength else { return redacted }
            return String(redacted.prefix(maxStringLength)) + "...[truncated]"
        }

        let context = snapshot.contextSnapshot.map { context in
            TurnContextSnapshot(
                promptMessages: context.promptMessages.map {
                    .init(role: clean($0.role), content: clean($0.content), tokenCount: $0.tokenCount)
                }
            )
        }

        return TurnSnapshot(
            timestamp: snapshot.timestamp,
            timelineID: snapshot.timelineID,
            agentID: snapshot.agentID,
            modelName: clean(snapshot.modelName),
            modelRoundIndex: snapshot.modelRoundIndex,
            maxModelRounds: snapshot.maxModelRounds,
            systemInstructions: snapshot.systemInstructions.map(clean),
            contextSnapshot: context,
            availableToolIDs: snapshot.availableToolIDs.map(clean),
            fullResponse: clean(snapshot.fullResponse),
            fullThinking: clean(snapshot.fullThinking),
            audioOutput: snapshot.audioOutput.map {
                .init(format: $0.format, byteCount: $0.byteCount, transcript: clean($0.transcript))
            },
            toolCalls: snapshot.toolCalls.map {
                .init(name: clean($0.name), arguments: clean($0.arguments), turn: $0.turn)
            },
            toolResults: snapshot.toolResults.map {
                .init(toolCallID: clean($0.toolCallID), name: clean($0.name), output: clean($0.output), turn: $0.turn)
            },
            turnDuration: snapshot.turnDuration,
            tokensPerSecond: snapshot.tokensPerSecond,
            usage: snapshot.usage,
            promptCacheReport: snapshot.promptCacheReport
        )
    }

    private static func redactSecrets(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)(api[_-]?key|token|secret|password|authorization|bearer)\s*[:=]\s*[\"']?[^\s,\"']+"#,
            #"\bsk-[A-Za-z0-9_-]+\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED]")
        }
        return result
    }
}
