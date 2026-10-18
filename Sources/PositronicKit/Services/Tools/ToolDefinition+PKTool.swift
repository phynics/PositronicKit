import Foundation
import PKContracts
import PKUtilities

extension ToolDefinition {
    /// Creates a definition from an existing `PKTool` instance.
    ///
    /// `PKTool.parametersSchema` is the typed `JSONSchema.Schema`; `ToolDefinition` stores
    /// the `[String: AnyCodable]` wire/transfer form (it must stay `Codable`/`Hashable` for
    /// `ToolReference`), so the schema is encoded to the dictionary form here.
    public init(from tool: any PKTool) {
        self.init(
            id: tool.callName,
            name: tool.name,
            description: tool.toolDescription,
            parametersSchema: tool.parametersSchema.asDictionary,
            usageExample: tool.usageExample,
            requiresPermission: tool.requiresPermission
        )
    }
}
