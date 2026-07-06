import Foundation
import Logging
import PKPrompt
import PKShared

/// Owns follow-up prompt synthesis for the ReAct loop: building an incremental follow-up
/// `RenderedPrompt` after tool/plugin messages are appended, without O(n²) re-rendering.
///
/// Extracted from `ChatEngine` (PKARCH-001). The incremental-string assembly (PKR-10) is
/// preserved: each follow-up appends only the new section's text to the already-rendered
/// accumulated string rather than re-joining every prior section from scratch.
struct PromptSnapshotBuilder {
    let logger: Logger

    func buildFollowUpSnapshot(
        from context: ChatTurnContext,
        appendedMessages: [LLMMessage],
        nextTurnIndex: Int
    ) async -> (renderedPrompt: RenderedPrompt?, promptHistoryUpdate: PromptHistoryUpdate?) {
        guard let priorRenderedPrompt = context.renderedPrompt else {
            return (context.renderedPrompt, context.promptHistoryUpdate)
        }

        let followUpPrompt = synthesizeFollowUpPrompt(
            from: priorRenderedPrompt,
            appendedMessages: appendedMessages,
            nextTurnIndex: nextTurnIndex
        )

        guard let promptHistory = context.promptHistory else {
            return (followUpPrompt, context.promptHistoryUpdate)
        }

        let update = await promptHistory.update(prompt: followUpPrompt)
        return (followUpPrompt, update)
    }

    func synthesizeFollowUpPrompt(
        from basePrompt: RenderedPrompt,
        appendedMessages: [LLMMessage],
        nextTurnIndex: Int
    ) -> RenderedPrompt {
        guard !appendedMessages.isEmpty else {
            return basePrompt
        }

        let sectionID = "runtime-follow-up-\(nextTurnIndex)"
        let appendedSection = RenderedPrompt.Section(
            id: sectionID,
            role: .chatHistory,
            priority: PromptPriority.medium.rawValue,
            estimatedTokens: PKShared.TokenEstimator.estimate(parts: appendedMessages.map(\.content)),
            compression: .keep,
            type: .list,
            cachePolicy: .volatile,
            path: ["runtime", "follow_up", "\(nextTurnIndex)"],
            parentID: nil,
            compressionOutcome: nil,
            content: .messages(appendedMessages.map(makeHistoryMessage))
        )

        var sectionsByID = basePrompt.sectionsByID
        let appendedContent = appendedMessages.map(\.content).joined(separator: "\n")
        sectionsByID[sectionID] = appendedContent

        let sections = basePrompt.sections + [appendedSection]

        // Build the rendered string incrementally: append the new section's text to the
        // already-rendered accumulated string instead of re-joining every prior section from
        // scratch each turn. This avoids O(n^2) string work across long tool-call loops (PKR-10).
        // Matches `AssembledPrompt.render()`'s behavior of skipping empty section content.
        let string = appendedContent.isEmpty
            ? basePrompt.string
            : basePrompt.string.isEmpty
            ? appendedContent
            : basePrompt.string + "\n\n---\n\n" + appendedContent

        return RenderedPrompt(
            sections: sections,
            string: string,
            sectionsByID: sectionsByID
        )
    }

    func makeHistoryMessage(_ message: LLMMessage) -> Message {
        let role: Message.MessageRole = switch message.role {
        case .system:
            .system
        case .user, .developer:
            .user
        case .assistant:
            .assistant
        case .tool:
            .tool
        }

        return Message(
            content: message.content,
            role: role,
            toolCalls: message.toolCalls?.compactMap { toolCall in
                let arguments: [String: Any]
                do {
                    guard let parsed = try JSONSerialization.jsonObject(with: Data(toolCall.arguments.utf8)) as? [String: Any] else {
                        throw NSError(domain: "ChatEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "tool-call arguments are not a JSON object"])
                    }
                    arguments = parsed
                } catch {
                    // Previously a silent `try?` dropped the tool call entirely from synthesized
                    // follow-up history on malformed arguments, leaving the turn loop with no
                    // record that the call was attempted. Log a warning and preserve the prior
                    // fallback (drop the call) — see STAB-12. Behavior is unchanged; we now leave
                    // a diagnostic trace including the tool name and a truncated raw payload.
                    let truncated = toolCall.arguments.prefix(120)
                    logger.warning("Dropping tool call '\(toolCall.name)' from history: arguments are not a JSON object. rawPrefix=\(String(truncated))")
                    return nil
                }
                return ToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    arguments: arguments.mapValues { AnyCodable($0) }
                )
            },
            toolCallId: message.toolCallID
        )
    }
}
