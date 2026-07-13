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

    init(messageStore: any MessageStoreProtocol, logger: Logger? = nil) {
        self.messageStore = messageStore
        self.logger = logger ?? Logger.module(named: "message-persistence")
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

        let streamUsage = await context.outputs.streamUsage
        let turnDuration = await context.outputs.turnDuration
        let tokensPerSecond = await context.outputs.tokensPerSecond

        let snapshot = await buildTurnSnapshot(from: context)
        let snapshotData = try? SerializationUtils.jsonEncoder.encode(snapshot)

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
            timelineId: context.timelineId,
            role: .assistant,
            content: fullResponse,
            recalledMemories: recalledMemories,
            reasoning: fullThinking.isEmpty ? nil : fullThinking,
            toolCalls: toolCallsJSON,
            agentInstanceId: context.agentInstanceId,
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
                let truncated = String(value.args.prefix(120))
                logger.warning("Persisting tool call '\(value.name)' with empty arguments: decode failed (\(error.localizedDescription)). rawPrefix=\(truncated)")
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
            timelineId: context.timelineId,
            agentInstanceId: context.agentInstanceId,
            modelName: context.modelName,
            turnCount: context.turnCount,
            maxTurns: context.maxTurns,
            systemInstructions: context.systemInstructions,
            contextSnapshot: contextSnapshot,
            availableToolIds: context.availableTools.map { $0.callName },
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
