import Foundation

/// Encapsulates the outcome of a tool execution.
public struct ToolResult: Sendable, Codable {
    /// Whether the execution was successful.
    public let isSuccess: Bool

    /// The string output of the tool, shown to the LLM on success.
    public let output: String

    /// Optional error message, shown to the LLM on failure.
    public let error: String?

    /// Workspace resolved for a workspace-dispatch call, if applicable.
    public let workspaceID: UUID?

    /// Whether workspace routing was explicit (`at` supplied) or implicit (one match).
    public let workspaceRouting: WorkspaceToolRouting?

    private enum CodingKeys: String, CodingKey {
        case isSuccess = "success"
        case output, error, workspaceID, workspaceRouting
    }

    public init(
        isSuccess: Bool,
        output: String,
        error: String?,
        workspaceID: UUID? = nil,
        workspaceRouting: WorkspaceToolRouting? = nil
    ) {
        self.isSuccess = isSuccess
        self.output = output
        self.error = error
        self.workspaceID = workspaceID
        self.workspaceRouting = workspaceRouting
    }

    /// Creates a successful tool result.
    public static func success(
        _ output: String,
        workspaceID: UUID? = nil,
        workspaceRouting: WorkspaceToolRouting? = nil
    )
        -> ToolResult {
        ToolResult(
            isSuccess: true,
            output: output,
            error: nil,
            workspaceID: workspaceID,
            workspaceRouting: workspaceRouting
        )
    }

    /// Creates a failed tool result with an error message.
    public static func failure(
        _ error: String,
        workspaceID: UUID? = nil,
        workspaceRouting: WorkspaceToolRouting? = nil
    ) -> ToolResult {
        ToolResult(
            isSuccess: false,
            output: "",
            error: error,
            workspaceID: workspaceID,
            workspaceRouting: workspaceRouting
        )
    }
}
