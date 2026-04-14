import Foundation
import Logging
import PKPrompt
import PKShared
import OpenAI

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

    func process(_ context: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let hasPendingToolCalls = await !context.outputs.toolCallAccumulators.isEmpty
        let toolCallsJSON = await buildToolCallsJSON(from: context, hasPendingToolCalls: hasPendingToolCalls)

        let fullResponse = await context.outputs.fullResponse
        let fullThinking = await context.outputs.fullThinking
        let streamUsage = await context.outputs.streamUsage
        let turnDuration = await context.outputs.turnDuration
        let tokensPerSecond = await context.outputs.tokensPerSecond

        let recalledMemories: String
        if hasPendingToolCalls {
            recalledMemories = "[]"
        } else {
            let memories = context.contextData.memories.map { $0.memory }
            recalledMemories = (try? SerializationUtils.jsonEncoder.encode(memories))
                .flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
        }

        let assistantMsg = ConversationMessage(
            timelineId: context.timelineId,
            role: .assistant,
            content: fullResponse,
            recalledMemories: recalledMemories,
            think: fullThinking.isEmpty ? nil : fullThinking,
            toolCalls: toolCallsJSON,
            agentInstanceId: context.agentInstanceId
        )
        try await messageStore.saveMessage(assistantMsg)

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
                        duration: turnDuration,
                        tokensPerSecond: tokensPerSecond,
                        turnSnapshotData: snapshotData
                    )
                ))
            }
            continuation.finish()
        }
    }

    private func buildToolCallsJSON(from context: ChatTurnContext, hasPendingToolCalls: Bool) async -> String {
        guard hasPendingToolCalls else { return "[]" }
        let sortedCalls = await context.outputs.toolCallAccumulators.sorted(by: { $0.key < $1.key })
        let callsForDB = sortedCalls.compactMap { _, value -> ToolCall? in
            let argsData = value.args.data(using: .utf8) ?? Data()
            let args = (try? SerializationUtils.jsonDecoder.decode([String: AnyCodable].self, from: argsData)) ?? [:]
            return ToolCall(name: value.name, arguments: args)
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
            availableToolIds: context.availableTools.map { $0.id },
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
        from param: ChatQuery.ChatCompletionMessageParam
    ) -> (role: String, content: String) {
        switch param {
        case let .system(msg):
            let text: String
            if case let .textContent(t) = msg.content { text = t } else { text = "\(msg.content)" }
            return ("system", text)
        case let .user(msg):
            let text: String
            if case let .string(t) = msg.content { text = t } else { text = "\(msg.content)" }
            return ("user", text)
        case let .assistant(msg):
            guard let content = msg.content else { return ("assistant", "") }
            let text: String
            if case let .textContent(t) = content { text = t } else { text = "\(content)" }
            return ("assistant", text)
        case let .tool(msg):
            let text: String
            if case let .textContent(t) = msg.content { text = t } else { text = "\(msg.content)" }
            return ("tool", text)
        case let .developer(msg):
            let text: String
            if case let .textContent(t) = msg.content { text = t } else { text = "\(msg.content)" }
            return ("developer", text)
        }
    }
}
