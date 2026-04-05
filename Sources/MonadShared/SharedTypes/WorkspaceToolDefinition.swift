import Foundation

/// Minimal definition of a tool for transfer
public struct WorkspaceToolDefinition: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let parametersSchema: [String: AnyCodable]
    public var usageExample: String?
    public var requiresPermission: Bool
    public var contextInjection: String?

    public init(
        id: String,
        name: String,
        description: String,
        parametersSchema: [String: AnyCodable] = [:],
        usageExample: String? = nil,
        requiresPermission: Bool = false,
        contextInjection: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.usageExample = usageExample
        self.requiresPermission = requiresPermission
        self.contextInjection = contextInjection
    }
}
