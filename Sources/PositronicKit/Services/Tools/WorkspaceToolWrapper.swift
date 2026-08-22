import Foundation
import struct JSONSchema.Schema
import PKContracts
import PKUtilities

/// Wraps a tool from a workspace tool provider to conform to the Tool protocol.
public struct WorkspaceToolWrapper: Tool, Sendable {
    public let workspace: any WorkspaceToolProvider
    public let definition: WorkspaceToolDefinition

    public var callName: String { definition.id }
    public var name: String { definition.name }
    public var description: String { definition.description }
    public var requiresPermission: Bool { definition.requiresPermission }
    public var usageExample: String? { definition.usageExample }

    public var parametersSchema: Schema {
        // WorkspaceToolDefinition stores the wire/transfer `[String: AnyCodable]` form; rebuild
        // the typed `Schema` the Tool protocol now expects.
        Schema(definition.parametersSchema)
    }

    public init(workspace: any WorkspaceToolProvider, definition: WorkspaceToolDefinition) {
        self.workspace = workspace
        self.definition = definition
    }

    public func canExecute() async -> Bool {
        return await workspace.healthCheck()
    }

    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        // parameters is already [String: AnyCodable] — the workspace protocol's executeTool
        // takes the same type, so no conversion is needed.
        let result = try await workspace.executeTool(id: callName, parameters: parameters)

        if result.success {
            return .success(result.output)
        } else {
            return .failure(result.error ?? "Unknown error during workspace tool execution")
        }
    }
}
