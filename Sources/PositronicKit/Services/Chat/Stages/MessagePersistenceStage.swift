import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

/// Pipeline stage responsible for persisting the assistant message and emitting the completion event.
///
/// Always saves the assistant message produced by the LLM turn:
/// - With `toolCalls` JSON when the LLM requested tool calls (pending execution).
/// - Without `toolCalls` when the response is a plain text reply.
///
/// After this stage, `ChatEngine.runChatLoop` inspects `context.outputs.toolCallAccumulators` to decide
/// whether to invoke `ToolRouter.handlePendingToolCalls` and continue the loop.
struct MessagePersistenceStage: PipelineStage {
    let messageStore: any MessageStoreProtocol
    let logger: Logger
    let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
    let loggingConfiguration: LoggingConfiguration

    init(
        messageStore: any MessageStoreProtocol,
        logger: Logger? = nil,
        diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default
        , loggingConfiguration: LoggingConfiguration = .default
    ) {
        self.messageStore = messageStore
        self.logger = logger ?? Logger.module(named: "message-persistence")
        self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
        self.loggingConfiguration = loggingConfiguration
    }

    func process(_ context: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
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

    private func buildSnapshotData(from context: ChatTurnContext) async -> Data? {
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

    /// Builds the assistant `ConversationMessage` from accumulated turn outputs.
    ///
    /// Shared between the success path (this stage, `status == nil` → `.complete`) and
    /// `ChatEngine`'s failure/cancellation error path (`status == .partial` / `.failed` /
    /// `.cancelled`), so a partial turn is persisted with the *same* shape as a complete
    /// one and differs only in the `status` tag. The success-path output is unchanged:
    /// `status` defaults to `nil`, which encodes away and round-trips as `.complete`
    /// (STAB-1).
    static func buildAssistantMessage(
        from context: ChatTurnContext,
        hasPendingToolCalls: Bool,
        status: Message.MessageStatus?,
        logger: Logger
    ) async -> ConversationMessage {
        let toolCallsJSON = await buildToolCallsJSON(
            from: context,
            hasPendingToolCalls: hasPendingToolCalls,
            logger: logger
        )

        let fullResponse = await context.outputs.fullResponse
        let fullThinking = await context.outputs.fullThinking

        let recalledMemories: String
        if hasPendingToolCalls {
            recalledMemories = "[]"
        } else {
            let memories = context.contextData.memories.map { $0.memory }
            recalledMemories = (try? SerializationUtils.jsonEncoder.encode(memories))
                .flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
        }

        return ConversationMessage(
            timelineID: context.timelineId,
            role: .assistant,
            content: fullResponse,
            recalledMemories: recalledMemories,
            reasoning: fullThinking.isEmpty ? nil : fullThinking,
            toolCalls: toolCallsJSON,
            agentInstanceID: context.agentInstanceId,
            status: status
        )
    }

    private static func buildToolCallsJSON(
        from context: ChatTurnContext,
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

    private func buildTurnSnapshot(from context: ChatTurnContext) async -> TurnSnapshot {
        let debugToolCalls = await context.outputs.debugToolCalls
        let debugToolResults = await context.outputs.debugToolResults
        let fullResponse = await context.outputs.fullResponse
        let fullThinking = await context.outputs.fullThinking
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

        let contextSnapshot = TurnContextSnapshot(
            promptMessages: promptMessages,
            files: context.contextData.notes.map {
                TurnContextSnapshot.FileEntry(name: $0.name, source: $0.source)
            },
            memories: context.contextData.memories.map {
                TurnContextSnapshot.MemoryEntry(
                    id: $0.memory.id,
                    content: $0.memory.content,
                    similarity: $0.similarity
                )
            },
            generatedTags: context.contextData.generatedTags,
            augmentedQuery: context.contextData.augmentedQuery,
            executionTime: context.contextData.executionTime
        )

        return TurnSnapshot(
            timelineID: context.timelineId,
            agentInstanceID: context.agentInstanceId,
            modelName: context.modelName,
            turnCount: context.turnCount,
            maxTurns: context.maxTurns,
            systemInstructions: context.systemInstructions,
            contextSnapshot: contextSnapshot,
            availableToolIDs: context.availableTools.map { $0.callName },
            fullResponse: fullResponse,
            fullThinking: fullThinking,
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
                },
                files: context.files.map { .init(name: clean($0.name), source: clean($0.source)) },
                memories: context.memories.map {
                    .init(id: $0.id, content: clean($0.content), similarity: $0.similarity)
                },
                generatedTags: context.generatedTags.map(clean),
                augmentedQuery: context.augmentedQuery.map(clean),
                executionTime: context.executionTime
            )
        }

        return TurnSnapshot(
            timestamp: snapshot.timestamp,
            timelineID: snapshot.timelineID,
            agentInstanceID: snapshot.agentInstanceID,
            modelName: clean(snapshot.modelName),
            turnCount: snapshot.turnCount,
            maxTurns: snapshot.maxTurns,
            systemInstructions: snapshot.systemInstructions.map(clean),
            contextSnapshot: context,
            availableToolIDs: snapshot.availableToolIDs.map(clean),
            fullResponse: clean(snapshot.fullResponse),
            fullThinking: clean(snapshot.fullThinking),
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
