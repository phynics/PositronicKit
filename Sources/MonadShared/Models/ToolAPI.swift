import Foundation

public struct ToolInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let isEnabled: Bool
    public let source: String?

    public init(
        id: String, name: String, description: String, isEnabled: Bool = true, source: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
        self.source = source
    }
}
