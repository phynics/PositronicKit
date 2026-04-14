import Foundation
import Logging
import PKShared

/// Parser for streaming LLM responses with Chain of Thought support
///
/// Handles streaming responses that contain `<think>...</think>` blocks,
/// separating reasoning from main content in real-time.
public struct StreamingParser {
    // MARK: - State

    public private(set) var buffer = ""
    public private(set) var thinking = ""
    public private(set) var content = ""

    public private(set) var isThinking = false
    public private(set) var insideCodeBlock = false
    public private(set) var hasReclassified = false

    private var rawBuffer = "" // Debug history

    public init() {}

    // MARK: - Public API

    public mutating func process(_ chunk: String) {
        hasReclassified = false
        buffer += chunk
        rawBuffer += chunk

        // Strip LLM formatting tokens like <|tool_calls_section_begin|>, <|tool_call_begin|>, etc.
        // Some models (e.g. Qwen) emit tool calls as raw text with these pipe-delimited markers.
        stripPipeDelimitedMarkers()

        // Process buffer exhaustively
        while let result = extractNextSegment() {
            if result.isThinking {
                thinking += result.text
            } else {
                appendContentSegment(result.text)
            }
        }
    }

    /// Appends a content segment, handling reclassification markers.
    private mutating func appendContentSegment(_ text: String) {
        if text.contains("RECLASSIFY_THINKING_MARKER") {
            Logger.module(named: "parser").warning("[Parser] ORPHANED </think> DETECTED! Reclassifying.")
            let actualText = text.replacingOccurrences(
                of: "RECLASSIFY_THINKING_MARKER", with: ""
            )
            thinking = content + actualText
            content = ""
            hasReclassified = true
        } else {
            content += text
        }
    }

    // MARK: - Pipe-Delimited Marker Stripping

    // Known LLM formatting token markers to strip from streaming output.
    private let pipeMarkerPattern = try! NSRegularExpression(
        pattern: #"<\|[a-z_]+\|>"#,
        options: []
    )

    /// Removes pipe-delimited markers like `<|tool_call_begin|>` from the buffer.
    private mutating func stripPipeDelimitedMarkers() {
        let range = NSRange(buffer.startIndex..., in: buffer)
        let cleaned = pipeMarkerPattern.stringByReplacingMatches(
            in: buffer, options: [], range: range, withTemplate: ""
        )
        if cleaned != buffer {
            buffer = cleaned
        }
    }

    // MARK: - Core Parsing Logic

    /// Extracts the next valid text segment from the buffer, updating state.
    private mutating func extractNextSegment() -> (text: String, isThinking: Bool)? {
        guard !buffer.isEmpty else { return nil }

        if let result = tryExtractCodeBlock() { return result }
        if holdingPartialCodeDelimiter() { return nil }

        if !insideCodeBlock {
            if let result = tryExtractThinkTags() { return result }
            if holdingPartialThinkTag() { return nil }
        }

        return flushBuffer()
    }

    /// Tries to extract content around a code block delimiter ("```").
    private mutating func tryExtractCodeBlock() -> (text: String, isThinking: Bool)? {
        guard let range = buffer.range(of: "```") else { return nil }
        let prefix = String(buffer[..<range.lowerBound])
        buffer.removeSubrange(..<range.upperBound)
        insideCodeBlock.toggle()

        if !prefix.isEmpty {
            return (prefix, isThinking)
        }
        return ("```", isThinking)
    }

    /// Returns true if buffer ends with a partial code delimiter that needs more data.
    private func holdingPartialCodeDelimiter() -> Bool {
        buffer.count < 1000 && (buffer.hasSuffix("``") || buffer.hasSuffix("`"))
    }

    /// Returns true if buffer ends with a partial <think> or </think> tag.
    private func holdingPartialThinkTag() -> Bool {
        guard let start = buffer.lastIndex(of: "<") else { return false }
        let suffix = String(buffer[start...])
        return "<think>".hasPrefix(suffix) || "</think>".hasPrefix(suffix)
    }

    /// Tries to extract content around `<think>` / `</think>` tags.
    private mutating func tryExtractThinkTags() -> (text: String, isThinking: Bool)? {
        if isThinking {
            return tryExtractClosingThinkTag()
        } else {
            return tryExtractOpeningThinkTag()
        }
    }

    /// Handles extraction when inside a `<think>` block.
    private mutating func tryExtractClosingThinkTag() -> (text: String, isThinking: Bool)? {
        if let range = buffer.range(of: "</think>") {
            let text = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            isThinking = false
            return (text, true)
        }

        return tryHoldPartialTag("</think>", asThinking: true)
    }

    /// Handles extraction when outside a `<think>` block.
    private mutating func tryExtractOpeningThinkTag() -> (text: String, isThinking: Bool)? {
        // Check for opening <think>
        if let range = buffer.range(of: "<think>") {
            let text = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            isThinking = true

            if !text.isEmpty {
                return (text, false)
            }
            return extractNextSegment()
        }

        // Check for partial opening or closing tag at end
        if let result = tryHoldPartialTag("<think>", asThinking: false) { return result }
        if let result = tryHoldPartialTag("</think>", asThinking: false) { return result }

        // Check for full orphaned closing tag (Reclassify Workaround)
        if let range = buffer.range(of: "</think>") {
            let contentBeforeTag = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            return (contentBeforeTag + "RECLASSIFY_THINKING_MARKER", false)
        }

        return nil
    }

    /// Holds content before a partial tag at the end of the buffer.
    private mutating func tryHoldPartialTag(
        _ tag: String, asThinking: Bool
    ) -> (text: String, isThinking: Bool)? {
        guard let start = buffer.lastIndex(of: "<") else { return nil }
        let suffix = buffer[start...]
        guard tag.hasPrefix(String(suffix)) else { return nil }

        if start > buffer.startIndex {
            let text = String(buffer[..<start])
            buffer = String(suffix)
            return (text, asThinking)
        }
        return nil
    }

    /// Flushes the remaining buffer as a single segment.
    private mutating func flushBuffer() -> (text: String, isThinking: Bool) {
        let text = buffer
        buffer = ""
        return (text, isThinking)
    }

    // MARK: - Tool Parsing

    /// Extract tool calls from text containing XML tags
    public func extractToolCalls(from text: String) -> (cleanText: String, toolCalls: [ToolCall]) {
        var cleanText = text
        var toolCalls: [ToolCall] = []

        // Pattern handles optional code fences around <tool_call>
        let pattern = "(?:```(?:xml)?\\s*)?<tool_call>(.*?)</tool_call>(?:\\s*```)?"

        guard
            let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            )
        else { return (text, []) }

        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

        // Process in reverse to preserve ranges during replacement
        for match in matches.reversed() {
            let fullRange = match.range
            let contentRange = match.range(at: 1)

            let jsonString = nsString.substring(with: contentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let jsonData = jsonString.data(using: .utf8),
               let toolCall = try? JSONDecoder().decode(ToolCall.self, from: jsonData) {
                toolCalls.append(toolCall)
            } else {
                Logger.module(named: "parser").error("Failed to parse tool call JSON: \(jsonString)")
            }

            cleanText = (cleanText as NSString).replacingCharacters(in: fullRange, with: "")
        }

        return (cleanText, toolCalls.reversed())
    }
}
