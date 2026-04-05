import Foundation
import MonadShared

/// Wraps a tool from a workspace to conform to the Tool protocol
public struct WorkspaceToolWrapper: Tool, Sendable {
    public let workspace: any WorkspaceProtocol
    public let definition: WorkspaceToolDefinition

    public var id: String { definition.id }
    public var name: String { definition.name }
    public var description: String { definition.description }
    public var requiresPermission: Bool { definition.requiresPermission }
    public var usageExample: String? { definition.usageExample }

    public var parametersSchema: [String: AnyCodable] {
        definition.parametersSchema
    }

    public init(workspace: any WorkspaceProtocol, definition: WorkspaceToolDefinition) {
        self.workspace = workspace
        self.definition = definition
    }

    public func canExecute() async -> Bool {
        return await workspace.healthCheck()
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        // Convert to AnyCodable for workspace protocol
        let codableParams = parameters.mapValues { AnyCodable($0) }

        // Execute on the workspace
        let result = try await workspace.executeTool(id: id, parameters: codableParams)

        if result.success {
            return .success(result.output)
        } else {
            return .failure(result.error ?? "Unknown error during workspace tool execution")
        }
    }
}
