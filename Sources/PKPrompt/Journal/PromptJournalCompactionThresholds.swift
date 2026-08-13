import Foundation

/// Thresholds that control when append pressure should trigger compaction.
///
/// Shared between `PromptJournal` (PKPrompt) and `ThreadPromptHistory` (runtime) via
/// `AppendPressure` — the surviving public name for the unified compaction-pressure core.
/// Each consumer owns its own post-compact action (base promotion or snapshot reset); this
/// type only carries the threshold configuration.
public struct PromptJournalCompactionThresholds: Sendable, Equatable, Codable {
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
