import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// STAB-1 — Resolves the partial assistant row for a turn whose LLM stream failed or was
/// cancelled mid-flight, so it is not silently lost.
///
/// `MessagePersistenceStage` only runs on the success path, so a turn that died after the
/// user had already watched partial text/thinking stream in was never persisted — a silent
/// data-loss. This mirrors the stage's message-building logic (via
/// `MessagePersistenceStage.buildAssistantMessage`) so the partial row has the *same* shape
/// as a complete one and differs only in its `status` tag (`.partial` for failure,
/// `.cancelled` for cancellation).
///
/// This type only *builds* the message — it does not persist it. `TurnEngine.completeTerminalOutcome`
/// passes the result as `ThreadRuntimeRepository.completeTurn`'s `finalMessage`, so the row and the
/// terminal Turn outcome commit in the same atomic transaction (ADR 0003, ADR 0007) instead of a
/// separate `saveMessage` call ahead of it — a crash between the two used to leave an assistant row
/// on a Thread whose Turn was still recorded active.
///
/// Extracted from `TurnEngine` (PKARCH-001).
///
/// Threshold: persistence is skipped when `context.outputs` has no assistant text, no
/// thinking, *and* no accumulated tool calls — a spurious empty assistant row would
/// misrepresent the turn (the already-persisted user message remains the turn's record).
/// A failed turn that emitted *anything* (even a single content char) is still persisted.
struct PartialAssistantPersistence {
    let logger: Logger

    init(logger: Logger? = nil) {
        self.logger = logger ?? Logger.module(named: "partial-assistant-persistence")
    }

    /// Resolves the assistant message (if any) that belongs in the terminal transaction for a
    /// non-`.completed` outcome. Returns `nil` when there is nothing to attach — either because
    /// the response was already durably saved on a different path, or because the turn produced
    /// no content worth recording.
    func partialAssistantMessage(
        context: TurnContext,
        status: Message.MessageStatus
    ) async -> ThreadMessage? {
        // The normal persistence stage runs before extension stages. If a later stage fails, the
        // complete assistant row is already durable (saved directly alongside pending tool calls
        // mid-loop) and must not be duplicated as a partial row.
        if await context.outputs.assistantResponseDurable {
            return nil
        }

        // The built-in persistence stage constructs the terminal assistant before package
        // extension stages run, deferring its persistence to the terminal transaction. If a later
        // extension fails, attach that complete response rather than manufacturing a `.partial`
        // duplicate. The terminal Turn will still be recorded as failed by the coordinator, but
        // the already-generated assistant content remains usable for inspection and retry.
        if let terminalMessage = await context.outputs.terminalAssistantMessage {
            return terminalMessage
        }

        let fullResponse = await context.outputs.fullResponse
        let fullThinking = await context.outputs.fullThinking
        let hasAudio = await !context.outputs.audioData.isEmpty
        let hasToolCalls = await !context.outputs.toolCallAccumulators.isEmpty

        guard !fullResponse.isEmpty || !fullThinking.isEmpty || hasAudio || hasToolCalls else {
            return nil
        }

        let assistantMsg = await MessagePersistenceStage.buildAssistantMessage(
            from: context,
            hasPendingToolCalls: hasToolCalls,
            status: status,
            logger: logger
        )
        logger.warning(
            "Resolved partial assistant turn for thread \(context.threadID) status=\(status.rawValue) contentChars=\(fullResponse.count) thinkingChars=\(fullThinking.count) toolCalls=\(hasToolCalls)"
        )
        return assistantMsg
    }
}
