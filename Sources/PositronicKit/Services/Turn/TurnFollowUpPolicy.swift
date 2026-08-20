import Foundation
import Logging
import PKContracts
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
/// Extracting this logic keeps `TurnEngine` focused on loop orchestration while preserving the
/// existing runtime behavior in one place.
enum TurnFollowUpPolicy {
    static func pluginMessages(
        for context: TurnContext,
        modelRoundIndex: Int,
        accumulatedOutput: String,
        plugins: [any TurnPlugin],
        logger: Logger
    ) async throws -> [LLMMessage] {
        let completedTurn = CompletedTurn(
            threadID: context.threadID,
            agentID: context.agentId,
            modelRoundIndex: modelRoundIndex,
            fullResponse: accumulatedOutput,
            modelName: context.modelName
        )

        var injectedMessages: [LLMMessage] = []
        do {
            for plugin in plugins {
                injectedMessages += try await plugin.afterTurn(completedTurn)
            }
        } catch {
            logger.error("Plugin error after turn \(modelRoundIndex): \(error)")
            throw error
        }

        return injectedMessages
    }

    static func shouldContinueWithPluginMessages(
        _ messages: [LLMMessage],
        modelRoundIndex: Int,
        maxModelRounds: Int
    ) -> Bool {
        !messages.isEmpty && modelRoundIndex < maxModelRounds
    }
}
