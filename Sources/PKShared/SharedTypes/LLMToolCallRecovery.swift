import Foundation

public struct LLMToolCallRecoveryState: Sendable, Equatable {
    public var hasYielded = false
    public var sawStreamedToolCalls = false
    public var finishedWithToolCalls = false

    public init() {}

    public mutating func observe(
        yieldedContent: Bool,
        streamedToolCalls: Bool,
        finishedWithToolCalls: Bool
    ) {
        if yieldedContent {
            hasYielded = true
        }
        if streamedToolCalls {
            hasYielded = true
            sawStreamedToolCalls = true
        }
        if finishedWithToolCalls {
            self.finishedWithToolCalls = true
        }
    }

    public var shouldRecoverToolCalls: Bool {
        finishedWithToolCalls && !sawStreamedToolCalls
    }

    public var shouldRetryAfterError: Bool {
        !hasYielded
    }
}
