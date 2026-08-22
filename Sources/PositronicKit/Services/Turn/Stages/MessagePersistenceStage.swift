import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// Pipeline stage responsible for persisting the assistant message and emitting the completion event.
///
/// Always saves the assistant message produced by the LLM turn:
/// - With `toolCalls` JSON when the LLM requested tool calls (pending execution).
/// - Without `toolCalls` when the response is a plain text reply.
///
/// After this stage, `TurnEngine.runTurnLoop` inspects `context.outputs.toolCallAccumulators` to decide
/// whether to invoke `ToolRouter.handlePendingToolCalls` and continue the loop.
struct MessagePersistenceStage: PipelineStage {
    let messageStore: any ThreadMessageStoreProtocol
    let logger: Logger
    let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
    let loggingConfiguration: LoggingConfiguration

    init(
        messageStore: any ThreadMessageStoreProtocol,
        logger: Logger? = nil,
        diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default
        , loggingConfiguration: LoggingConfiguration = .default
    ) {
        self.messageStore = messageStore
        self.logger = logger ?? Logger.module(named: "message-persistence")
        self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
        self.loggingConfiguration = loggingConfiguration
    }

    func process(_ context: TurnContext) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        let hasPendingToolCalls = await !context.outputs.toolCallAccumulators.isEmpty
        let fullResponse = await context.outputs.fullResponse
        let streamFinishReason = await context.outputs.streamFinishReason

        let assistantMsg = await Self.buildAssistantMessage(
            from: context,
            hasPendingToolCalls: hasPendingToolCalls,
            status: nil,
            logger: logger
        )
        try await messageStore.saveMessage(assistantMsg)
        await context.outputs.markAssistantResponseDurable()

        let streamUsage = await context.outputs.streamUsage
        let turnDuration = await context.outputs.turnDuration
        let tokensPerSecond = await context.outputs.tokensPerSecond

        let snapshotData = await buildSnapshotData(from: context)

        return AsyncThrowingStream { continuation in
            if !hasPendingToolCalls {
                continuation.yield(.generationCompleted(
                    message: assistantMsg.toMessage(),
                    metadata: APIResponseMetadata(
                        model: context.modelName,
                        promptTokens: streamUsage?.promptTokens,
                        completionTokens: streamUsage?.completionTokens,
                        totalTokens: streamUsage?.totalTokens,
                        cachedTokens: streamUsage?.promptTokensDetails?.cachedTokens,
                        finishReason: streamFinishReason,
                        duration: turnDuration,
                        tokensPerSecond: tokensPerSecond,
                        turnSnapshotData: snapshotData
                    )
                ))
                if fullResponse.isEmpty, let streamFinishReason {
                    continuation.yield(.completedEmpty(finishReason: streamFinishReason))
                }
            }
            continuation.finish()
        }
    }

    private func buildSnapshotData(from context: TurnContext) async -> Data? {
        switch diagnosticSnapshotConfiguration.policy {
        case .off, .metadataOnly:
            return nil
        case .redacted, .full:
            let snapshot = await buildTurnSnapshot(from: context)
            return DiagnosticSnapshotEncoder.encode(
                snapshot,
                policy: diagnosticSnapshotConfiguration.policy,
                maxBytes: diagnosticSnapshotConfiguration.maxBytes
            )
        }
    }

    /// Builds the assistant `ThreadMessage` from accumulated turn outputs.
    ///
    /// Shared between the success path (this stage, `status == nil` → `.complete`) and
    /// `TurnEngine`'s failure/cancellation error path (`status == .partial` / `.failed` /
    /// `.cancelled`), so a partial turn is persisted with the *same* shape as a complete
    /// one and differs only in the `status` tag. The success-path output is unchanged:
    /// `status` defaults to `nil`, which encodes away and round-trips as `.complete`
    /// (STAB-1).
    static func buildAssistantMessage(
        from context: TurnContext,
        hasPendingToolCalls: Bool,
        status: Message.MessageStatus?,
        logger: Logger
    ) async -> ThreadMessage {
        let toolCallsJSON = await buildToolCallsJSON(
            from: context,
            hasPendingToolCalls: hasPendingToolCalls,
            logger: logger
        )

        let fullResponse = await context.outputs.fullResponse
        let fullThinking = await context.outputs.fullThinking
        let audioData = await context.outputs.audioData
        let audioFormat = await context.outputs.audioFormat
        let audioTranscript = await context.outputs.audioTranscript
        let audioContinuation = await context.outputs.audioContinuation

        var contentParts: [MessageContentPart] = []
        if !fullResponse.isEmpty { contentParts.append(.text(fullResponse)) }
        if !audioData.isEmpty, let audioFormat {
            contentParts.append(.audio(AudioContent(
                data: audioData,
                format: audioFormat,
                transcript: audioTranscript.isEmpty ? nil : audioTranscript,
                continuation: audioContinuation
            )))
        }

        return ThreadMessage(
            threadID: context.threadID,
            role: .assistant,
            content: MessageContent(parts: contentParts),
            reasoning: fullThinking.isEmpty ? nil : fullThinking,
            toolCalls: toolCallsJSON,
            agentID: context.agentId,
            executionKind: context.executionKind,
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

    private func buildTurnSnapshot(from context: TurnContext) async -> TurnSnapshot {
        let debugToolCalls = await context.outputs.debugToolCalls
        let debugToolResults = await context.outputs.debugToolResults
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
            threadID: context.threadID,
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
            toolCalls: debugToolCalls,
            toolResults: debugToolResults,
            turnDuration: turnDuration,
            tokensPerSecond: tokensPerSecond,
            promptTokens: streamUsage?.promptTokens,
            completionTokens: streamUsage?.completionTokens,
            totalTokens: streamUsage?.totalTokens,
            cachedTokens: streamUsage?.promptTokensDetails?.cachedTokens
        )
    }

    // MARK: - Message Extraction

    private static func extractRoleAndContent(
        from param: LLMMessage
    ) -> (role: String, content: String) {
        (param.role.rawValue, param.content)
    }
}

private enum DiagnosticSnapshotEncoder {
    static func encode(
        _ snapshot: TurnSnapshot,
        policy: DiagnosticSnapshotPolicy,
        maxBytes: Int
    ) -> Data? {
        guard maxBytes > 0 else { return nil }
        let initialLimit = policy == .redacted ? 512 : Int.max
        var limit = initialLimit

        while limit >= 0 {
            let candidate = sanitized(snapshot, maxStringLength: limit)
            if let data = try? SerializationUtils.jsonEncoder.encode(candidate), data.count <= maxBytes {
                return data
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
            threadID: snapshot.threadID,
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
            promptTokens: snapshot.promptTokens,
            completionTokens: snapshot.completionTokens,
            totalTokens: snapshot.totalTokens,
            cachedTokens: snapshot.cachedTokens
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
