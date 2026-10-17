import Foundation
import PKContracts

/// Errors raised when the runtime's prompt budget is constructed with invalid capacities.
enum PromptBudgetError: PKError, Sendable, Equatable {
    /// The context-window size was zero or negative.
    case nonPositiveContextWindow(Int)
    /// The output reserve (response limit plus provider overhead) was negative.
    case negativeOutputReserve(Int)
    /// The output reserve consumed the entire context window, leaving no room for the prompt.
    case outputReserveExceedsContextWindow(contextWindow: Int, reserve: Int)

    var errorDomain: String {
        PKErrorDomain.turn
    }

    var errorCode: Int {
        switch self {
        case .nonPositiveContextWindow: 9011
        case .negativeOutputReserve: 9012
        case .outputReserveExceedsContextWindow: 9013
        }
    }

    var userFriendlyMessage: String {
        switch self {
        case let .nonPositiveContextWindow(value):
            "The model context window must be a positive number of tokens (got \(value))."
        case let .negativeOutputReserve(value):
            "The response output reserve must not be negative (got \(value))."
        case let .outputReserveExceedsContextWindow(contextWindow, reserve):
            "The response output reserve (\(reserve) tokens) leaves no room for the prompt within the \(contextWindow)-token context window."
        }
    }

    var remediation: String? {
        switch self {
        case .nonPositiveContextWindow:
            "Set a positive `contextWindowTokens` on the provider configuration for the active model."
        case .negativeOutputReserve:
            "Lower `GenerationParameters.maxTokens` or the provider overhead so the reserve is non-negative."
        case .outputReserveExceedsContextWindow:
            "Lower `GenerationParameters.maxTokens` or use a model with a larger context window so the prompt fits."
        }
    }
}

/// The runtime's provider prompt budget.
///
/// The runtime never compresses or summarizes prompt content. The budget only bounds stepwise
/// history trimming and the non-history overflow check that fails preparation with
/// ``TurnError/promptExceedsContextWindow(estimated:limit:)``. Projection and trimming receive
/// their bounds from here.
///
/// The prompt budget is `contextWindowTokens - reserveForResponse`. This deliberately does
/// **not** infer context capacity from the output limit: a small `maxTokens` (for example 512)
/// does not shrink the whole prompt budget.
struct PromptBudget: Sendable, Equatable {
    /// The model's full context-window size in tokens.
    let contextWindowTokens: Int
    /// Tokens withheld from the context window for the model response and provider overhead.
    let reserveForResponse: Int

    /// The tokens available to the provider prompt: `contextWindowTokens - reserveForResponse`.
    var availableTokens: Int { contextWindowTokens - reserveForResponse }

    init(contextWindowTokens: Int, reserveForResponse: Int) {
        self.contextWindowTokens = contextWindowTokens
        self.reserveForResponse = reserveForResponse
    }

    /// Creates a validated budget from a context-window size and the tokens reserved for the
    /// model's response (the output limit plus any provider overhead).
    ///
    /// - Parameters:
    ///   - contextWindowTokens: The model's full context-window size in tokens. Must be positive.
    ///   - outputReserve: Tokens withheld for the response and provider overhead. Must be
    ///     non-negative and strictly less than `contextWindowTokens`.
    /// - Throws: ``PromptBudgetError`` when the configuration leaves no room for the prompt.
    init(contextWindowTokens: Int, outputReserve: Int) throws {
        guard contextWindowTokens > 0 else {
            throw PromptBudgetError.nonPositiveContextWindow(contextWindowTokens)
        }
        guard outputReserve >= 0 else {
            throw PromptBudgetError.negativeOutputReserve(outputReserve)
        }
        guard outputReserve < contextWindowTokens else {
            throw PromptBudgetError.outputReserveExceedsContextWindow(
                contextWindow: contextWindowTokens,
                reserve: outputReserve
            )
        }
        self.contextWindowTokens = contextWindowTokens
        self.reserveForResponse = outputReserve
    }
}
