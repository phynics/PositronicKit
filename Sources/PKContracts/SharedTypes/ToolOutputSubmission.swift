import Foundation

/// A caller-supplied result for a pending assistant tool call, submitted back into the runtime to
/// continue a later model round after host-side execution (for example, after user approval).
public struct ToolOutputSubmission: Codable, Sendable {
    /// The id of the tool call this output resolves.
    public let toolCallID: String
    /// The tool's output content to feed back to the model.
    public let output: String

    public init(toolCallID: String, output: String) {
        self.toolCallID = toolCallID
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallID = "toolCallId"
        case output
    }
}
