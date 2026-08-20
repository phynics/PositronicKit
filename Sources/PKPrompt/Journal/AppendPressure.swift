import Foundation
import PKContracts
import PKUtilities

/// Shared append-pressure accounting consumed by both `PromptJournal` (PKPrompt) and
/// `ThreadPromptHistory` (runtime).
///
/// Owns the append counters + threshold evaluation only. Post-compact action — promoting the
/// latest observation into a committed base (PKPrompt) or resetting the base snapshot / last
/// diff (runtime) — stays consumer-specific. Call `reset()` after the consumer-specific
/// post-compact work is done.
package struct AppendPressure: Sendable {
    package private(set) var appendedMessageCount: Int = 0
    package private(set) var appendedTokens: Int = 0
    package let thresholds: PromptJournalCompactionThresholds

    package init(thresholds: PromptJournalCompactionThresholds = .default) {
        self.thresholds = thresholds
    }

    package init(
        thresholds: PromptJournalCompactionThresholds,
        appendedMessageCount: Int,
        appendedTokens: Int
    ) {
        self.thresholds = thresholds
        self.appendedMessageCount = appendedMessageCount
        self.appendedTokens = appendedTokens
    }

    package var shouldCompact: Bool {
        appendedTokens > thresholds.maxAppendedTokens
            || appendedMessageCount > thresholds.maxAppendedMessages
    }

    package mutating func recordAppend(messageCount: Int, estimatedTokens: Int) {
        appendedMessageCount += messageCount
        appendedTokens += estimatedTokens
    }

    package mutating func recordAppend(messages: [Message]) {
        recordAppend(
            messageCount: messages.count,
            estimatedTokens: TokenEstimator.estimate(parts: messages.map(\.content))
        )
    }

    package mutating func reset() {
        appendedMessageCount = 0
        appendedTokens = 0
    }
}
