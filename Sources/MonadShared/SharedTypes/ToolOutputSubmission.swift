import Foundation

public struct ToolOutputSubmission: Codable, Sendable {
    public let toolCallId: String
    public let output: String

    public init(toolCallId: String, output: String) {
        self.toolCallId = toolCallId
        self.output = output
    }
}
