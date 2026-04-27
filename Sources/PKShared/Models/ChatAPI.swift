import Foundation

public struct ChatRequest: Codable, Sendable {
    public let message: String
    public let toolOutputs: [ToolOutputSubmission]?
    public let requestOriginId: UUID?
    public let attachedTools: [ToolReference]?

    public init(
        message: String,
        toolOutputs: [ToolOutputSubmission]? = nil,
        requestOriginId: UUID? = nil,
        attachedTools: [ToolReference]? = nil
    ) {
        self.message = message
        self.toolOutputs = toolOutputs
        self.requestOriginId = requestOriginId
        self.attachedTools = attachedTools
    }
}

public extension ChatRequest {
    var clientId: UUID? { requestOriginId }
    var clientTools: [ToolReference]? { attachedTools }
}

public struct ChatResponse: Codable, Sendable {
    public let response: String

    public init(response: String) {
        self.response = response
    }
}
