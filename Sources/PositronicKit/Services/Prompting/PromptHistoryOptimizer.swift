import Foundation
import PKContracts
import PKUtilities

/// Stateless history budgeting policy used during prompt assembly.
enum PromptHistoryOptimizer {
    /// The maximum number of tokens allowed for chat history in a prompt.
    static let maxHistoryTokens = 120_000
    /// A buffer reserved for non-history sections so history does not crowd them out.
    static let historyTokenBuffer = 4000

    public static func optimizeForDefaultBudget(_ messages: [Message]) -> [Message] {
        optimize(messages, availableTokens: maxHistoryTokens - historyTokenBuffer)
    }

    /// Truncates conversation history to fit within a specified token budget.
    /// Keeps the most recent messages and inserts a truncation notice if needed.
    public static func optimize(
        _ messages: [Message],
        availableTokens: Int
    ) -> [Message] {
        guard availableTokens > 0 else { return [] }

        var result: [Message] = []
        var usedTokens = 0

        for message in messages.reversed() {
            let tokens = TokenEstimator.estimate(text: message.content)
            if usedTokens + tokens <= availableTokens {
                result.insert(message, at: 0)
                usedTokens += tokens
            } else {
                if result.count < messages.count, availableTokens >= 100 {
                    let skippedCount = messages.count - result.count
                    let summary = Message(
                        content: "[System: History truncated. \(skippedCount) earlier messages hidden. " +
                            "Use `view_chat_history` tool to retrieve them.]",
                        role: .system,
                        isSummary: true
                    )
                    result.insert(summary, at: 0)
                }
                break
            }
        }
        return result
    }
}
