import Foundation

/// The format used to surface tool calls to a model.
///
/// Prior to PKCLEAN-007 this enum also offered `.json` and `.xml` cases for
/// non-OpenAI-style tool calling. Those cases were dead options: nothing in the
/// runtime ever read `toolFormat` to branch behavior, and no provider adapter
/// implemented them, so they only misled users into thinking they could opt out
/// of native tool calling. They have been removed; `.openAI` (native,
/// provider-side tool calling) is the only supported format.
///
/// `Codable` decoding is intentionally lenient: an on-disk config file predating
/// this change may still carry a stale `"JSON"` or `"XML"` raw value. Rather than
/// throwing, any unrecognized raw value decodes to `.openAI`, so old configs keep
/// loading without a migration. Encoding still emits the canonical
/// `"Native (OpenAI)"` raw value.
public enum ToolCallFormat: String, CaseIterable, Identifiable, Sendable {
    case openAI = "Native (OpenAI)"

    public var id: String {
        rawValue
    }
}

extension ToolCallFormat: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ToolCallFormat(rawValue: raw) ?? .openAI
    }
}
