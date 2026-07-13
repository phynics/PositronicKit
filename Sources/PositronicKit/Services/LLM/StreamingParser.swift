import Foundation
import Logging
import PKShared
import PKUtilities

/// Parser for streaming LLM responses with Chain of Thought support
///
/// Handles streaming responses that contain `<think>...</think>` blocks,
/// separating reasoning from main content in real-time.
struct StreamingParser {
    // MARK: - State

    private(set) var buffer = ""
    private(set) var thinking = ""
    private(set) var content = ""

    private(set) var isThinking = false
    private(set) var insideCodeBlock = false
    private(set) var hasReclassified = false

    private var rawBuffer = "" // Debug history

    init() {}

    // MARK: - Public API

    mutating func process(_ chunk: String) {
        hasReclassified = false
        buffer += chunk
        rawBuffer += chunk

        // Strip LLM formatting tokens like <|tool_calls_section_begin|>, <|tool_call_begin|>, etc.
        // Some models (e.g. Qwen) emit tool calls as raw text with these pipe-delimited markers.
        stripPipeDelimitedMarkers()

        // Process buffer exhaustively
        while let result = extractNextSegment() {
            if result.reclassify {
                // An orphaned </think> closed a thinking block that never opened: everything
                // emitted so far (plus this segment) was actually reasoning.
                Logger.module(named: "parser").warning("[Parser] ORPHANED </think> DETECTED! Reclassifying.")
                thinking = content + result.text
                content = ""
                hasReclassified = true
            } else if result.isThinking {
                thinking += result.text
            } else {
                content += result.text
            }
        }
    }

    // MARK: - Pipe-Delimited Marker Stripping

    /// Known LLM formatting token markers to strip from streaming output.
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

    /// A parsed chunk of streamed output.
    /// `reclassify` is set only when an orphaned `</think>` requires moving already-emitted
    /// content into the thinking channel; it carries no payload through the text itself.
    private typealias Segment = (text: String, isThinking: Bool, reclassify: Bool)

    /// Extracts the next valid text segment from the buffer, updating state.
    private mutating func extractNextSegment() -> Segment? {
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
    private mutating func tryExtractCodeBlock() -> Segment? {
        guard let range = buffer.range(of: "```") else { return nil }
        let prefix = String(buffer[..<range.lowerBound])
        buffer.removeSubrange(..<range.upperBound)
        insideCodeBlock.toggle()

        if !prefix.isEmpty {
            return (prefix, isThinking, false)
        }
        return ("```", isThinking, false)
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
    private mutating func tryExtractThinkTags() -> Segment? {
        if isThinking {
            return tryExtractClosingThinkTag()
        } else {
            return tryExtractOpeningThinkTag()
        }
    }

    /// Handles extraction when inside a `<think>` block.
    private mutating func tryExtractClosingThinkTag() -> Segment? {
        if let range = buffer.range(of: "</think>") {
            let text = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            isThinking = false
            return (text, true, false)
        }

        return tryHoldPartialTag("</think>", asThinking: true)
    }

    /// Handles extraction when outside a `<think>` block.
    private mutating func tryExtractOpeningThinkTag() -> Segment? {
        // Check for opening <think>
        if let range = buffer.range(of: "<think>") {
            let text = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            isThinking = true

            if !text.isEmpty {
                return (text, false, false)
            }
            return extractNextSegment()
        }

        // Check for partial opening or closing tag at end
        if let result = tryHoldPartialTag("<think>", asThinking: false) { return result }
        if let result = tryHoldPartialTag("</think>", asThinking: false) { return result }

        // Check for a full orphaned closing tag: a `</think>` with no matching opener. Signal
        // reclassification via the segment flag rather than embedding a marker in the text.
        if let range = buffer.range(of: "</think>") {
            let contentBeforeTag = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            return (contentBeforeTag, false, true)
        }

        return nil
    }

    /// Holds content before a partial tag at the end of the buffer.
    private mutating func tryHoldPartialTag(
        _ tag: String, asThinking: Bool
    ) -> Segment? {
        guard let start = buffer.lastIndex(of: "<") else { return nil }
        let suffix = buffer[start...]
        guard tag.hasPrefix(String(suffix)) else { return nil }

        if start > buffer.startIndex {
            let text = String(buffer[..<start])
            buffer = String(suffix)
            return (text, asThinking, false)
        }
        return nil
    }

    /// Flushes the remaining buffer as a single segment.
    private mutating func flushBuffer() -> Segment {
        let text = buffer
        buffer = ""
        return (text, isThinking, false)
    }

    // MARK: - Tool Parsing

    /// Extract tool calls from text containing XML tags
    func extractToolCalls(from text: String) -> (cleanText: String, toolCalls: [ToolCall]) {
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
               let toolCall = try? JSONDecoder().decode(ToolCall.self, from: jsonData)
            {
                toolCalls.append(toolCall)
            } else {
                Logger.module(named: "parser").error("Failed to parse tool call JSON: \(jsonString)")
            }

            cleanText = (cleanText as NSString).replacingCharacters(in: fullRange, with: "")
        }

        return (cleanText, toolCalls.reversed())
    }
}
