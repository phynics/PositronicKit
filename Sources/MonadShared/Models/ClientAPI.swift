import Foundation

public struct ClientRegistrationRequest: Codable, Sendable {
    public let hostname: String
    public let displayName: String
    public let platform: String
    public let tools: [ToolReference]

    public init(hostname: String, displayName: String, platform: String, tools: [ToolReference] = []) {
        self.hostname = hostname
        self.displayName = displayName
        self.platform = platform
        self.tools = tools
    }
}

public struct ClientRegistrationResponse: Codable, Sendable {
    public let client: ClientIdentity
    public let defaultWorkspace: WorkspaceReference

    public init(client: ClientIdentity, defaultWorkspace: WorkspaceReference) {
        self.client = client
        self.defaultWorkspace = defaultWorkspace
    }
}
