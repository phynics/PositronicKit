import Foundation

/// Errors raised when provider-bound LLM message history violates a shared contract.
public enum LLMMessageValidationError: PKError, Sendable, Equatable {
    /// A tool result cannot be correlated with an assistant tool call without its identifier.
    case missingToolCallID

    public var errorDomain: String {
        PKErrorDomain.llm
    }

    public var errorCode: Int {
        1005
    }

    public var userFriendlyMessage: String {
        "Tool-result history contains a tool message without a tool call ID."
    }

    public var remediation: String? {
        "Set toolCallID to the ID from the matching assistant tool call before sending the message history."
    }
}

/// Validates the message history shared by provider adapters before it is serialized.
public func validateLLMMessageHistory(_ messages: [LLMMessage]) throws {
    guard messages.contains(where: { message in
        message.role == .tool && (message.toolCallID?.isEmpty ?? true)
    }) == false else {
        throw LLMMessageValidationError.missingToolCallID
    }
}
