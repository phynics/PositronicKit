import Foundation

/// Reference to a tool available in a workspace
public enum ToolReference: Codable, Sendable, Hashable {
    case known(id: String)  // Server-known tool by ID
    case custom(definition: WorkspaceToolDefinition)  // Client-provided definition

    /// The tool ID regardless of type
    public var toolId: String {
        switch self {
        case .known(let id):
            return id
        case .custom(let definition):
            return definition.id
        }
    }

    /// The tool name for display
    public var displayName: String {
        switch self {
        case .known(let id):
            return id  // Server will resolve actual name
        case .custom(let definition):
            return definition.name
        }
    }

    /// Workspace-specific instructions for this tool
    public var contextInjection: String? {
        switch self {
        case .known:
            return nil  // Server tools don't have injected context yet
        case .custom(let definition):
            return definition.contextInjection
        }
    }

    /// Create a known tool reference
    public static func known(_ id: String) -> ToolReference {
        .known(id: id)
    }

    /// Create a custom tool reference from a definition
    public static func custom(_ definition: WorkspaceToolDefinition) -> ToolReference {
        .custom(definition: definition)
    }
}

extension ToolReference {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case definition
    }

    private enum ReferenceType: String, Codable {
        case known
        case custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ReferenceType.self, forKey: .type)

        switch type {
        case .known:
            let id = try container.decode(String.self, forKey: .id)
            self = .known(id: id)
        case .custom:
            let definition = try container.decode(WorkspaceToolDefinition.self, forKey: .definition)
            self = .custom(definition: definition)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .known(let id):
            try container.encode(ReferenceType.known, forKey: .type)
            try container.encode(id, forKey: .id)
        case .custom(let definition):
            try container.encode(ReferenceType.custom, forKey: .type)
            try container.encode(definition, forKey: .definition)
        }
    }
}
