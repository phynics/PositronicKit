import Foundation
import PKContracts
import PKUtilities

/// The per-Timeline memory of a stepwise history trim.
///
/// Once history crosses its budget, the runtime drops oldest messages down to 75% of the budget
/// at a tool-transaction boundary and keeps that cut until the budget is crossed again. The cut
/// is remembered here so later Turns reuse the same prefix instead of sliding every Turn.
struct HistoryTrimState: Sendable, Equatable {
    /// Number of oldest history messages currently trimmed away. Always a tool-transaction
    /// boundary index into the full history the cut was computed against.
    var droppedMessageCount: Int
    /// The budget the current cut was computed against. A later Turn with a different budget
    /// recomputes the cut even when the stored cut already fits.
    var budgetTokens: Int

    init(droppedMessageCount: Int = 0, budgetTokens: Int = 0) {
        self.droppedMessageCount = droppedMessageCount
        self.budgetTokens = budgetTokens
    }

    /// Whether a trim is currently in effect.
    var hasTrimmed: Bool { droppedMessageCount > 0 }
}

/// The outcome of one stepwise trim pass.
struct HistoryTrimResult: Sendable, Equatable {
    /// The retained history tail.
    let messages: [Message]
    /// The state to persist for the next Turn.
    let state: HistoryTrimState
    /// Whether this pass moved the cut, which signals one prefix reset.
    let didTrim: Bool
}

/// Stateless history budgeting policy used during prompt assembly.
enum PromptHistoryOptimizer {
    /// The maximum number of tokens allowed for chat history in a prompt.
    static let maxHistoryTokens = 120_000
    /// A buffer reserved for non-history sections so history does not crowd them out.
    static let historyTokenBuffer = 4000
    /// The default history budget when a caller does not supply a context-derived one.
    static var defaultHistoryBudget: Int { maxHistoryTokens - historyTokenBuffer }
    /// When history is over budget, the trim drops down to this fraction of the budget.
    static let trimTargetRatio = 0.75

    public static func optimizeForDefaultBudget(_ messages: [Message]) -> [Message] {
        stepwise(messages, availableTokens: defaultHistoryBudget, state: HistoryTrimState()).messages
    }

    /// Truncates timeline history to fit a budget with a stable, stepwise cut (#277).
    ///
    /// When the retained tail already fits the budget, the stored cut is kept. Only when it is
    /// over budget does the cut advance — to the earliest tool-transaction boundary whose suffix
    /// fits within 75% of the budget. That gives one prefix reset per trim instead of one per
    /// Turn.
    public static func optimize(
        _ messages: [Message],
        availableTokens: Int
    ) -> [Message] {
        stepwise(messages, availableTokens: availableTokens, state: HistoryTrimState()).messages
    }

    /// The stepwise trim described by the state parameter.
    static func stepwise(
        _ messages: [Message],
        availableTokens: Int,
        state: HistoryTrimState
    ) -> HistoryTrimResult {
        guard availableTokens > 0 else {
            return HistoryTrimResult(
                messages: [],
                state: HistoryTrimState(droppedMessageCount: messages.count, budgetTokens: 0),
                didTrim: !messages.isEmpty
            )
        }

        let start = min(max(state.droppedMessageCount, 0), messages.count)
        let retained = Array(messages[start...])
        let retainedTokens = estimatedTokens(retained)
        if retainedTokens <= availableTokens {
            // Keep the existing cut: the prefix stays byte-identical until the budget is crossed.
            return HistoryTrimResult(
                messages: retained,
                state: HistoryTrimState(droppedMessageCount: start, budgetTokens: availableTokens),
                didTrim: false
            )
        }

        let target = Int(Double(availableTokens) * trimTargetRatio)
        let cut = trimBoundary(in: messages, from: start, targetTokens: target)
        return HistoryTrimResult(
            messages: Array(messages[cut...]),
            state: HistoryTrimState(droppedMessageCount: cut, budgetTokens: availableTokens),
            didTrim: cut > start
        )
    }

    /// Finds the earliest tool-transaction boundary at or after `start` whose retained suffix
    /// fits within `targetTokens`.
    ///
    /// A boundary is the start index or any message that begins a new user/system turn. The cut
    /// never lands between an assistant tool call and its tool result, so a trimmed history stays
    /// a valid provider conversation. When even the empty tail fits, `messages.count` is returned.
    static func trimBoundary(in messages: [Message], from start: Int, targetTokens: Int) -> Int {
        guard start < messages.count else { return messages.count }

        for index in start ..< messages.count {
            let isBoundary = index == start || messages[index].role == .user || messages[index].role == .system
            guard isBoundary else { continue }
            if estimatedTokens(Array(messages[index...])) <= targetTokens {
                return index
            }
        }
        return messages.count
    }

    /// Estimated tokens across a message tail.
    static func estimatedTokens(_ messages: [Message]) -> Int {
        TokenEstimator.estimate(parts: messages.map(\.content))
    }
}
