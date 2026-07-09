import Foundation
import struct JSONSchema.Schema
import PKShared

/// Wraps a tool from a workspace to conform to the Tool protocol
public struct WorkspaceToolWrapper: Tool, Sendable {
    public let workspace: any WorkspaceProtocol
    public let definition: WorkspaceToolDefinition

    public var id: String { definition.id }
    public var name: String { definition.name }
    public var description: String { definition.description }
    public var requiresPermission: Bool { definition.requiresPermission }
    public var usageExample: String? { definition.usageExample }

    public var parametersSchema: Schema {
        // WorkspaceToolDefinition stores the wire/transfer `[String: AnyCodable]` form; rebuild
        // the typed `Schema` the Tool protocol now expects.
        Schema(definition.parametersSchema)
    }

    public init(workspace: any WorkspaceProtocol, definition: WorkspaceToolDefinition) {
        self.workspace = workspace
        self.definition = definition
    }

    public func canExecute() async -> Bool {
        return await workspace.healthCheck()
    }

    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        // parameters is already [String: AnyCodable] — the workspace protocol's executeTool
        // takes the same type, so no conversion is needed.
        let result = try await workspace.executeTool(id: id, parameters: parameters)

        if result.success {
            return .success(result.output)
        } else {
            return .failure(result.error ?? "Unknown error during workspace tool execution")
        }
    }
}
