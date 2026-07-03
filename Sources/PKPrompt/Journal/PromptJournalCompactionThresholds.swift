import Foundation

/// Thresholds that control when a ``PromptJournal`` should auto-compact its latest accepted
/// observation into a new committed base.
///
/// This mirrors the runtime-side append-pressure safety valve used by
/// `TimelinePromptHistory`, but keeps the prompt-facing journaling API independent from the
/// runtime implementation details.
public struct PromptJournalCompactionThresholds: Sendable, Equatable {
    /// Maximum estimated appended tokens before the next observation auto-compacts the journal.
    public let maxAppendedTokens: Int
    /// Maximum appended message count before the next observation auto-compacts the journal.
    public let maxAppendedMessages: Int

    public init(maxAppendedTokens: Int = 50000, maxAppendedMessages: Int = 40) {
        self.maxAppendedTokens = maxAppendedTokens
        self.maxAppendedMessages = maxAppendedMessages
    }

    public static let `default` = PromptJournalCompactionThresholds()
}
