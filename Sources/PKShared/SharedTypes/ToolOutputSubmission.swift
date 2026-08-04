import Foundation

/// A caller-supplied result for a pending tool call, submitted back into the runtime to
/// resume a turn that is waiting on tool execution (e.g. after user approval).
public struct ToolOutputSubmission: Codable, Sendable {
    /// The id of the tool call this output resolves.
    public let toolCallID: String
    /// The tool's output content to feed back to the model.
    public let output: String

    public init(toolCallID: String, output: String) {
        self.toolCallID = toolCallID
        self.output = output
    }

    /// Creates a submission using the legacy identifier spelling.
    @available(*, deprecated, message: "Use init(toolCallID:output:).")
    public init(toolCallId: String, output: String) {
        self.init(toolCallID: toolCallId, output: output)
    }

    /// The tool-call identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "toolCallID")
    public var toolCallId: String { toolCallID }

    private enum CodingKeys: String, CodingKey {
        case toolCallID = "toolCallId"
        case output
    }
}
