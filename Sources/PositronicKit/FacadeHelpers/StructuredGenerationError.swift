import PKContracts

/// Errors raised before a typed structured-generation request can reach the model.
public enum StructuredGenerationError: PKError, Sendable, Equatable {
    /// The requested type's generated schema could not be constructed for Draft 2020-12.
    case schemaConstructionFailed(typeName: String, reason: String)

    public var errorDomain: String {
        PKErrorDomain.llm
    }

    public var errorCode: Int {
        1101
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .schemaConstructionFailed(typeName, reason):
            return "The structured-output schema for \(typeName) could not be constructed: \(reason)"
        }
    }

    public var remediation: String? {
        switch self {
        case let .schemaConstructionFailed(typeName, _):
            return "Update \(typeName) so its generated schema is valid Draft 2020-12 JSON Schema, then try again."
        }
    }
}
