import Foundation
import PKShared

extension WorkspaceToolDefinition {
    /// Create from an existing Tool protocol instance
    public init(from tool: any Tool) {
        self.init(
            id: tool.id,
            name: tool.name,
            description: tool.description,
            parametersSchema: tool.parametersSchema,
            usageExample: tool.usageExample,
            requiresPermission: tool.requiresPermission
        )
    }
}
