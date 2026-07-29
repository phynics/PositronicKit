import Foundation
import PKShared

/// Errors raised when concrete prompt sections cannot form a valid assembled prompt.
public enum PromptAssemblyError: PKError, Sendable, Equatable {
    /// Two or more concrete sections shared the same stable identifier.
    case duplicateSectionIDs([String])

    /// More than one concrete section declared itself as the active user query.
    case multipleUserQuerySections([String])

    public var errorDomain: String { PKErrorDomain.prompt }

    public var errorCode: Int {
        switch self {
        case .duplicateSectionIDs: return 1001
        case .multipleUserQuerySections: return 1002
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .duplicateSectionIDs(ids):
            return "Prompt assembly found duplicate section identifiers: \(ids.joined(separator: ", "))."
        case let .multipleUserQuerySections(ids):
            return "Prompt assembly found multiple user-query sections: \(ids.joined(separator: ", "))."
        }
    }

    public var remediation: String? {
        switch self {
        case .duplicateSectionIDs:
            return "Ensure each prompt section uses a unique stable identifier."
        case .multipleUserQuerySections:
            return "Mark only one concrete section as the active user query in the assembled prompt."
        }
    }
}
