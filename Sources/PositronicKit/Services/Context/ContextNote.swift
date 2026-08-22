import PKContracts
import PKUtilities
import Foundation

public struct ContextNote: Sendable, Codable, CustomStringConvertible {
    public let name: String
    public let content: String
    public let source: String  // e.g. "Notes/Welcome.md"

    public var description: String {
        return "ContextNote(name: \(name), source: \(source))"
    }

    public init(name: String, content: String, source: String) {
        self.name = name
        self.content = content
        self.source = source
    }
}
