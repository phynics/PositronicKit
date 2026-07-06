import ErrorKit
import Foundation
import Logging
import PKShared

/// Projects tool execution outcomes into chat events, persisted messages, and provider-neutral
/// follow-up messages.
///
/// `ToolRouter` still owns orchestration, but this helper isolates the side-effectful mapping from
/// execution results to conversation artifacts so those semantics can be tested independently.
enum ToolTurnProjector {
    /// Yields the `.attempting` tool-progress event that precedes the execution attempt. Pinning
    /// this projection here (PKARCH-002) keeps all tool-event projection in one module — the
    /// caller (`ToolRouter.handlePendingToolCalls`) invokes this before dispatching to
    /// `ToolExecutor` or the external-deferral branch.
    static func projectAttempt(
        call: ParsedToolCall,
        toolRef: ToolReference,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) {
        continuation.yield(.toolProgress(
            toolCallId: call.callId,
            status: .attempting(name: call.name, reference: toolRef)
        ))
    }

    static func projectOutcome(
        _ outcome: ToolExecutionOutcome,
        call: ParsedToolCall,
        timelineId: UUID,
        logger: Logger,
        messageStore: any MessageStoreProtocol,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> LLMMessage? {
        let toolDisplayName = ANSIColors.colorize(call.name, color: ANSIColors.brightCyan)
        switch outcome {
        case let .completed(output):
            logger.info("Tool \(toolDisplayName) succeeded")
            continuation.yield(.toolCompleted(toolCallId: call.callId, status: .success(ToolResult.success(output))))
            try await messageStore.saveMessage(
                ConversationMessage(timelineId: timelineId, role: .tool, content: output, toolCallId: call.callId)
            )
            return LLMMessage(role: .tool, content: output, toolCallID: call.callId)

        case .deferredExternally:
            logger.info("Tool \(toolDisplayName) deferred for external execution")
            return nil
        }
    }

    static func projectError(
        _ error: Error,
        call: ParsedToolCall,
        toolRef: ToolReference,
        timelineId: UUID,
        logger: Logger,
        messageStore: any MessageStoreProtocol,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> LLMMessage {
        let toolDisplayName = ANSIColors.colorize(call.name, color: ANSIColors.brightCyan)
        let errorMsg = ErrorKit.userFriendlyMessage(for: error)
        logger.error("Tool \(toolDisplayName) error: \(error.localizedDescription)")
        // Surface the error's built-in remediation (a second-person "how to fix it" hint, often
        // with a worked example) back to the model so a failed tool call guides recovery rather
        // than dead-ending. Kept out of the steady-state prompt to stay lean — the model only
        // pays for this guidance on the turn it actually errors.
        var errorOutput = "Error: \(errorMsg)"
        if let remediation = (error as? any PKError)?.remediation, !remediation.isEmpty {
            errorOutput += "\nHow to fix: \(remediation)"
        }
        continuation.yield(.toolCompleted(
            toolCallId: call.callId,
            status: .failed(reference: toolRef, error: error.localizedDescription)
        ))
        try await messageStore.saveMessage(
            ConversationMessage(timelineId: timelineId, role: .tool, content: errorOutput, toolCallId: call.callId)
        )
        return LLMMessage(role: .tool, content: errorOutput, toolCallID: call.callId)
    }
}
