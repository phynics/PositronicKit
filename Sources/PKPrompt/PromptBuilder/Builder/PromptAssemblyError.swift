import Foundation

/// Errors raised when concrete prompt sections cannot form a valid assembled prompt.
public enum PromptAssemblyError: Error, Sendable, Equatable {
    /// Two or more concrete sections shared the same stable identifier.
    case duplicateSectionIDs([String])

    /// More than one concrete section declared itself as the active user query.
    case multipleUserQuerySections([String])
}
