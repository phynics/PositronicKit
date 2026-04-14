import Foundation

public enum ToolCallFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "Native (OpenAI)"
    case json = "JSON"
    case xml = "XML"

    public var id: String {
        rawValue
    }
}
