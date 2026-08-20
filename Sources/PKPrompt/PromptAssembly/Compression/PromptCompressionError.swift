import Foundation
import PKContracts

/// Errors raised when compression input or its execution plan is inconsistent.
public enum PromptCompressionError: PKError, Sendable, Equatable {
    /// The source sections contain more than one section with the same identifier.
    case duplicateSectionIDs([String])
    /// The compression plan contains more than one action for the same node.
    case duplicatePlannedNodeIDs([String])
    /// The compressed prompt still cannot fit in the available budget.
    case budgetUnsatisfied(availableTokens: Int, estimatedTokens: Int)
    /// A mandatory `.keep` section cannot fit in the available budget.
    case mandatorySectionOverflow(sectionID: String, estimatedTokens: Int, availableTokens: Int)

    public var errorDomain: String { PKErrorDomain.prompt }

    public var errorCode: Int {
        switch self {
        case .duplicateSectionIDs: return 1201
        case .duplicatePlannedNodeIDs: return 1202
        case .budgetUnsatisfied: return 1203
        case .mandatorySectionOverflow: return 1204
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .duplicateSectionIDs(ids):
            return "Prompt compression found duplicate section identifiers: \(ids.joined(separator: ", "))."
        case let .duplicatePlannedNodeIDs(ids):
            return "Prompt compression found duplicate planned node identifiers: \(ids.joined(separator: ", "))."
        case let .budgetUnsatisfied(availableTokens, estimatedTokens):
            return "Prompt compression could not fit the prompt in \(availableTokens) tokens (estimated \(estimatedTokens))."
        case let .mandatorySectionOverflow(sectionID, estimatedTokens, availableTokens):
            return "Mandatory prompt section '\(sectionID)' needs \(estimatedTokens) tokens but only \(availableTokens) are available."
        }
    }

    public var remediation: String? {
        switch self {
        case .duplicateSectionIDs, .duplicatePlannedNodeIDs:
            return "Ensure every prompt section and compression action has a unique stable identifier."
        case .budgetUnsatisfied, .mandatorySectionOverflow:
            return "Increase the prompt budget, reduce mandatory content, or choose a compressible strategy."
        }
    }
}
