import Foundation

/// Encapsulates the outcome of a tool execution.
public struct ToolResult: Sendable, Codable {
    /// Whether the execution was successful.
    public let success: Bool

    /// The string output of the tool, shown to the LLM on success.
    public let output: String

    /// Optional error message, shown to the LLM on failure.
    public let error: String?

    /// Creates a successful tool result.
    public static func success(_ output: String)
        -> ToolResult {
        ToolResult(success: true, output: output, error: nil)
    }

    /// Creates a failed tool result with an error message.
    public static func failure(_ error: String) -> ToolResult {
        ToolResult(success: false, output: "", error: error)
    }
}
