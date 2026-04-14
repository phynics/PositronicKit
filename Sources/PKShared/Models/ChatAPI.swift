import Foundation

public struct ChatRequest: Codable, Sendable {
    public let message: String
    public let toolOutputs: [ToolOutputSubmission]?
    public let clientId: UUID?
    public let clientTools: [ToolReference]?

    public init(
        message: String,
        toolOutputs: [ToolOutputSubmission]? = nil,
        clientId: UUID? = nil,
        clientTools: [ToolReference]? = nil
    ) {
        self.message = message
        self.toolOutputs = toolOutputs
        self.clientId = clientId
        self.clientTools = clientTools
    }
}

public struct ChatResponse: Codable, Sendable {
    public let response: String

    public init(response: String) {
        self.response = response
    }
}
