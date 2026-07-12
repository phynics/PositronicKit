import Foundation
import Logging
import PKShared
import PKUtilities

/// Runtime policy for deciding whether a completed turn should trigger a follow-up LLM turn.
///
/// Today this policy is intentionally narrow:
///
/// - tool-call continuation is handled separately by `ToolRouter`
/// - post-turn plugins may inject additional `LLMMessage`s
/// - if injected messages are non-empty and the loop has remaining turns, the chat loop continues
/// - otherwise the loop finishes
///
/// Extracting this logic keeps `ChatEngine` focused on loop orchestration while preserving the
/// existing runtime behavior in one place.
enum ChatTurnFollowUpPolicy {
    static func pluginMessages(
        for context: ChatTurnContext,
        turnCount: Int,
        accumulatedOutput: String,
        plugins: [any ChatTurnPlugin],
        logger: Logger
    ) async throws -> [LLMMessage] {
        let completedTurn = CompletedTurn(
            timelineId: context.timelineId,
            agentInstanceId: context.agentInstanceId,
            turnCount: turnCount,
            fullResponse: accumulatedOutput,
            modelName: context.modelName
        )

        var injectedMessages: [LLMMessage] = []
        do {
            for plugin in plugins {
                injectedMessages += try await plugin.afterTurn(completedTurn)
            }
        } catch {
            logger.error("Plugin error after turn \(turnCount): \(error)")
            throw error
        }

        return injectedMessages
    }

    static func shouldContinueWithPluginMessages(
        _ messages: [LLMMessage],
        turnCount: Int,
        maxTurns: Int
    ) -> Bool {
        !messages.isEmpty && turnCount < maxTurns
    }
}
