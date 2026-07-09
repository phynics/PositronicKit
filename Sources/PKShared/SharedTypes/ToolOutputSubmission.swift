import Foundation

/// A caller-supplied result for a pending tool call, submitted back into the runtime to
/// resume a turn that is waiting on tool execution (e.g. after user approval).
public struct ToolOutputSubmission: Codable, Sendable {
    /// The id of the tool call this output resolves.
    public let toolCallId: String
    /// The tool's output content to feed back to the model.
    public let output: String

    public init(toolCallId: String, output: String) {
        self.toolCallId = toolCallId
        self.output = output
    }
}
