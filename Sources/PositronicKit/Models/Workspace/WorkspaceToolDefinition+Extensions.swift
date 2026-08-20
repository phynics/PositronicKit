import Foundation
import PKContracts
import PKUtilities

extension WorkspaceToolDefinition {
    /// Create from an existing Tool protocol instance.
    ///
    /// `Tool.parametersSchema` is the typed `JSONSchema.Schema`; `WorkspaceToolDefinition` stores
    /// the `[String: AnyCodable]` wire/transfer form (it must stay `Codable`/`Hashable` for
    /// `ToolReference`), so the schema is encoded to the dictionary form here.
    public init(from tool: any Tool) {
        self.init(
            id: tool.callName,
            name: tool.name,
            description: tool.description,
            parametersSchema: tool.parametersSchema.asDictionary,
            usageExample: tool.usageExample,
            requiresPermission: tool.requiresPermission
        )
    }
}
