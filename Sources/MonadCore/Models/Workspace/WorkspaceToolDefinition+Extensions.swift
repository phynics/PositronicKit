import Foundation
import MonadShared

extension WorkspaceToolDefinition {
    /// Create from an existing Tool protocol instance
    public init(from tool: any Tool) {
        // Convert [String: Any] to [String: AnyCodable]
        var schema: [String: AnyCodable] = [:]
        for (key, value) in tool.parametersSchema {
            schema[key] = AnyCodable(value)
        }

        self.init(
            id: tool.id,
            name: tool.name,
            description: tool.description,
            parametersSchema: schema,
            usageExample: tool.usageExample,
            requiresPermission: tool.requiresPermission
        )
    }
}
