import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

/// STAB-1 — Persist a partial assistant turn when the LLM stream fails or is cancelled
/// mid-flight.
///
/// `MessagePersistenceStage` only runs on the success path, so a turn that died after the
/// user had already watched partial text/thinking stream in was never persisted — a silent
/// data-loss. This mirrors the stage's message-building logic (via
/// `MessagePersistenceStage.buildAssistantMessage`) so the partial row has the *same* shape
/// as a complete one and differs only in its `status` tag (`.partial` for failure,
/// `.cancelled` for cancellation). The error/cancelled event is still surfaced to the UI
/// by the caller; this type never swallows it.
///
/// Extracted from `ChatEngine` (PKARCH-001); behavior is unchanged.
///
/// Threshold: persistence is skipped when `context.outputs` has no assistant text, no
/// thinking, *and* no accumulated tool calls — a spurious empty assistant row would
/// misrepresent the turn (the already-persisted user message remains the turn's record).
/// A failed turn that emitted *anything* (even a single content char) is still persisted.
struct PartialAssistantPersistence {
    let messageStore: any MessageStoreProtocol
    let logger: Logger

    init(messageStore: any MessageStoreProtocol, logger: Logger? = nil) {
        self.messageStore = messageStore
        self.logger = logger ?? Logger.module(named: "partial-assistant-persistence")
    }

    func persistPartialAssistantIfNeeded(
        context: ChatTurnContext,
        status: Message.MessageStatus
    ) async {
        // The normal persistence stage runs before extension stages. If a later stage fails, the
        // complete assistant row is already durable and must not be duplicated as a partial row.
        if await context.outputs.assistantResponseDurable {
            return
        }

        let fullResponse = await context.outputs.fullResponse
        let fullThinking = await context.outputs.fullThinking
        let hasAudio = await !context.outputs.audioData.isEmpty
        let hasToolCalls = await !context.outputs.toolCallAccumulators.isEmpty

        guard !fullResponse.isEmpty || !fullThinking.isEmpty || hasAudio || hasToolCalls else {
            return
        }

        do {
            let assistantMsg = await MessagePersistenceStage.buildAssistantMessage(
                from: context,
                hasPendingToolCalls: hasToolCalls,
                status: status,
                logger: logger
            )
            try await messageStore.saveMessage(assistantMsg)
            logger.warning(
                "Persisted partial assistant turn for thread \(context.threadID) status=\(status.rawValue) contentChars=\(fullResponse.count) thinkingChars=\(fullThinking.count) toolCalls=\(hasToolCalls)"
            )
        } catch {
            logger.error(
                "Failed to persist partial assistant turn for thread \(context.threadID) status=\(status.rawValue): \(error)"
            )
        }
    }
}
