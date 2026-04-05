import Foundation
import MonadShared

/// Internal helper for decoding flexibility in tool call parsing.
private struct RawToolCall: Codable {
    let tool: String?
    let name: String?
    let args: [String: AnyCodable]?
    let arguments: [String: AnyCodable]?

    var resolvedName: String? {
        tool ?? name
    }

    var resolvedArgs: [String: AnyCodable]? {
        args ?? arguments
    }
}

/// Utility for parsing tool calls from raw text content when structured tool calls fail.
public enum ToolOutputParser {
    /// Represents a parsed tool call
    public struct FallbackToolCall: Codable {
        public let name: String
        public let arguments: [String: AnyCodable]

        public init(from decoder: Decoder) throws {
            let raw = try RawToolCall(from: decoder)
            guard let name = raw.resolvedName, let args = raw.resolvedArgs else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing required tool name or arguments"
                    )
                )
            }
            self.name = name
            arguments = args
        }

        public init(name: String, arguments: [String: AnyCodable]) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// Attempts to parse tool calls from a string that might contain XML-style tags or JSON code blocks.
    public static func parse(from content: String) -> [FallbackToolCall] {
        // A. Check for pipe-delimited tool call markers (e.g. Qwen models)
        let pipeCalls = parsePipeDelimitedCalls(from: content)
        if !pipeCalls.isEmpty { return pipeCalls }

        // B. Check for XML-style <tool_call> tags
        let xmlCalls = parseXMLToolCalls(from: content)
        if !xmlCalls.isEmpty { return xmlCalls }

        // C. Check for markdown code blocks (legacy/single call fallback)
        return parseCodeBlockCalls(from: content)
    }

    // MARK: - Pipe-Delimited Parsing

    private static func parsePipeDelimitedCalls(from content: String) -> [FallbackToolCall] {
        guard content.contains("<|tool_call_begin|>") || content.contains("tool_call_begin") else {
            return []
        }

        let pipePattern =
            #"(?:(?:<\|tool_call_begin\|>)|(?:tool_call_begin))\s*"# +
            #"(?:functions\.)?(\w+)(?::\d+)?\s*"# +
            #"(?:<\|tool_call_argument_begin\|>)?\s*"# +
            #"(\{[^}]*(?:\{[^}]*\}[^}]*)?\})\s*"# +
            #"(?:<\|tool_call_end\|>)?"#

        guard let regex = try? NSRegularExpression(pattern: pipePattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        var foundCalls: [FallbackToolCall] = []
        let contentRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: contentRange)

        for match in matches {
            if let nameRange = Range(match.range(at: 1), in: content),
               let argsRange = Range(match.range(at: 2), in: content) {
                let name = String(content[nameRange])
                let argsString = String(content[argsRange])
                if let data = argsString.data(using: .utf8),
                   let args = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
                    foundCalls.append(FallbackToolCall(name: name, arguments: args))
                }
            }
        }

        return foundCalls
    }

    // MARK: - XML Parsing

    private static func parseXMLToolCalls(from content: String) -> [FallbackToolCall] {
        guard let regex = try? NSRegularExpression(
            pattern: "(?s)<tool_call>(.*?)</tool_call>", options: []
        ) else { return [] }

        var foundCalls: [FallbackToolCall] = []
        let matches = regex.matches(in: content, options: [], range: NSRange(content.startIndex..., in: content))

        for match in matches {
            if let range = Range(match.range(at: 1), in: content) {
                let jsonString = String(content[range])
                if let data = jsonString.data(using: .utf8),
                   let call = try? JSONDecoder().decode(FallbackToolCall.self, from: data) {
                    foundCalls.append(call)
                }
            }
        }

        return foundCalls
    }

    // MARK: - Code Block Parsing

    private static func parseCodeBlockCalls(from content: String) -> [FallbackToolCall] {
        var cleaned = content

        if let range = cleaned.range(of: "```json", options: .caseInsensitive),
           let endRange = cleaned.range(of: "```", options: .backwards),
           range.upperBound < endRange.lowerBound {
            cleaned = String(cleaned[range.upperBound ..< endRange.lowerBound])
        } else if let range = cleaned.range(of: "```", options: .caseInsensitive),
                  let endRange = cleaned.range(of: "```", options: .backwards),
                  range.upperBound < endRange.lowerBound {
            cleaned = String(cleaned[range.upperBound ..< endRange.lowerBound])
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty, let data = cleaned.data(using: .utf8) else { return [] }

        if cleaned.hasPrefix("[") {
            if let calls = try? JSONDecoder().decode([FallbackToolCall].self, from: data) {
                return calls
            }
        } else {
            if let call = try? JSONDecoder().decode(FallbackToolCall.self, from: data) {
                return [call]
            }
        }

        return []
    }
}
