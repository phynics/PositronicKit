import Foundation

public struct RequestOriginRegistrationRequest: Codable, Sendable {
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

public struct RequestOriginRegistrationResponse: Codable, Sendable {
    public let origin: RequestOriginIdentity
    public let defaultWorkspace: WorkspaceReference

    public init(origin: RequestOriginIdentity, defaultWorkspace: WorkspaceReference) {
        self.origin = origin
        self.defaultWorkspace = defaultWorkspace
    }
}
