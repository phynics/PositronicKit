import MonadShared
import Foundation
/// Database model for a tool available in a workspace
public struct WorkspaceTool: Codable, Sendable, Identifiable {
    public let id: UUID
    public let workspaceId: UUID
    public let toolId: String
    public let isKnown: Bool
    public let definition: String?  // JSON string of WorkspaceToolDefinition if isKnown=false

    public init(
        id: UUID = UUID(),
        workspaceId: UUID,
        toolReference: ToolReference
    ) throws {
        self.id = id
        self.workspaceId = workspaceId
        self.toolId = toolReference.toolId

        switch toolReference {
        case .known:
            self.isKnown = true
            self.definition = nil
        case .custom(let def):
            self.isKnown = false
            let data = try JSONEncoder().encode(def)
            self.definition = String(data: data, encoding: .utf8)
        }
    }

    /// Convert back to ToolReference
    public func toToolReference() throws -> ToolReference {
        if isKnown {
            return .known(id: toolId)
        } else {
            guard let json = definition, let data = json.data(using: .utf8) else {
                throw WorkspaceToolError.missingDefinition
            }
            let def = try JSONDecoder().decode(WorkspaceToolDefinition.self, from: data)
            return .custom(definition: def)
        }
    }
}
