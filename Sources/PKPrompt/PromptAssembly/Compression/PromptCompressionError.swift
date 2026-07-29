import Foundation
import PKShared

/// Errors raised when compression input or its execution plan is inconsistent.
public enum PromptCompressionError: PKError, Sendable, Equatable {
    /// The source sections contain more than one section with the same identifier.
    case duplicateSectionIDs([String])
    /// The compression plan contains more than one action for the same node.
    case duplicatePlannedNodeIDs([String])

    public var errorDomain: String { PKErrorDomain.prompt }

    public var errorCode: Int {
        switch self {
        case .duplicateSectionIDs: return 1201
        case .duplicatePlannedNodeIDs: return 1202
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .duplicateSectionIDs(ids):
            return "Prompt compression found duplicate section identifiers: \(ids.joined(separator: ", "))."
        case let .duplicatePlannedNodeIDs(ids):
            return "Prompt compression found duplicate planned node identifiers: \(ids.joined(separator: ", "))."
        }
    }

    public var remediation: String? {
        "Ensure every prompt section and compression action has a unique stable identifier."
    }
}
