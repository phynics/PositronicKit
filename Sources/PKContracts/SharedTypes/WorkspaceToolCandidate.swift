import Foundation

/// How a Workspace was selected for a provider-facing tool call.
public enum WorkspaceToolRouting: String, Codable, Equatable, Hashable, Sendable {
    /// The model supplied the Workspace UUID in `call_tool(at:)`.
    case explicit
    /// The runtime selected the only authorized Workspace exposing the tool.
    case implicit
}

/// Describes one authorized workspace that can satisfy a workspace-tool call.
///
/// Candidates are intentionally value types so an ambiguity correction can be rendered from the
/// admission snapshot without consulting a workspace that may have changed since the Turn began.
public struct WorkspaceToolCandidate: Codable, Equatable, Hashable, Sendable {
    public let workspaceID: UUID
    public let label: String
    public let toolID: String
    public let toolName: String
    public let description: String
    public let parametersSchema: [String: AnyCodable]
    public let isPrimary: Bool

    public init(
        workspaceID: UUID,
        label: String,
        toolID: String,
        toolName: String,
        description: String,
        parametersSchema: [String: AnyCodable] = [:],
        isPrimary: Bool = false
    ) {
        self.workspaceID = workspaceID
        self.label = label
        self.toolID = toolID
        self.toolName = toolName
        self.description = description
        self.parametersSchema = parametersSchema
        self.isPrimary = isPrimary
    }
}
