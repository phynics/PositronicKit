import Foundation
import Logging
import PKContracts
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

    init() {}

    // MARK: - Public API

    mutating func process(_ chunk: String) {
        hasReclassified = false
        buffer += chunk

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
    ///
    /// Decisions depend only on the consumed prefix plus complete tokens, never on how
    /// the provider framed the stream into chunks: text is emitted only before the
    /// earliest complete special token, and any ambiguous trailing run is held until the
    /// next chunk arrives. Split and unsplit decodes therefore converge.
    private mutating func extractNextSegment() -> Segment? {
        guard !buffer.isEmpty else { return nil }

        // A trailing viable pipe-marker partial (`<|tool_call` awaiting `_end|>`) stays
        // buffered until the next chunk arrives. Text before it is still processed
        // eagerly via recursion — but when the head holds too (for example it ends with
        // a fence the next chunk could extend), everything stays buffered so split and
        // unsplit streams resolve markers identically. This check precedes token
        // dispatch so a fence before a pending partial is held rather than acted on.
        if let markerStart = partialPipeMarkerStart() {
            guard markerStart > buffer.startIndex else { return nil }
            let tail = String(buffer[markerStart...])
            buffer = String(buffer[..<markerStart])
            if let result = extractNextSegment() {
                buffer = buffer + tail
                return result
            }
            buffer = buffer + tail
            return nil
        }

        if insideCodeBlock {
            if let result = tryExtractCodeBlock() { return result }
        } else if !isThinking {
            // Act on the earliest of a fence, a think opener, or an orphaned closer. A
            // whole-buffer fence scan would let a later fence swallow an earlier think
            // tag in the unsplit stream while a split stream opens thinking first.
            if let result = tryExtractEarliestOuterToken() { return result }
        } else {
            // A fence inside thinking protects any think tags until the fence closes.
            // A closer before that fence still ends the thinking block first.
            if let result = tryExtractEarliestThinkingToken() { return result }
        }

        // Extract complete fences before considering a trailing backtick partial. A
        // three-backtick run is already a complete fence; only a one- or two-backtick
        // suffix needs to wait for the next chunk. This also lets a complete fence at
        // the end of a chunk toggle code-block state before the next chunk arrives.
        if holdingPartialCodeDelimiter() {
            if let result = extractSegmentBeforePartialCodeDelimiter() { return result }
            return nil
        }

        if !insideCodeBlock && !isThinking {
            if holdingPartialThinkTag() { return nil }
        } else if !insideCodeBlock {
            if let result = tryExtractThinkTags() { return result }
            if holdingPartialThinkTag() { return nil }
        }

        return flushBuffer()
    }

    /// Returns the start of a trailing partial pipe-delimited marker (`<|...|>`) that a
    /// later chunk could still complete, or nil when the buffer ends with no such marker.
    private func partialPipeMarkerStart() -> String.Index? {
        guard let start = buffer.lastIndex(of: "<") else { return nil }
        let suffix = String(buffer[start...])
        // The first `<` is itself ambiguous: the next chunk may begin with `|` and
        // complete a pipe marker. Keep it until the next chunk makes that decision.
        guard suffix == "<" || suffix.hasPrefix("<|"), !suffix.contains("|>") else { return nil }
        if suffix == "<" { return start }
        // Only `[a-z_]` (plus a single trailing `|` awaiting its `>`) can still grow
        // into a marker; anything else (e.g. `<|foo bar` or a plain `<div>`) can never
        // match and must be emitted normally.
        var inner = suffix.dropFirst(2)
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        guard inner.allSatisfy({ ("a" ... "z").contains($0) || $0 == "_" }) else { return nil }
        return start
    }

    /// Tries to extract content around a code block delimiter ("```").
    ///
    /// Fences are always consumed silently, never emitted as text: emitting a fence only
    /// when it happens to start the buffer would resolve the same stream differently
    /// depending on chunk framing.
    private mutating func tryExtractCodeBlock() -> Segment? {
        guard let range = buffer.range(of: "```") else { return nil }
        let prefix = String(buffer[..<range.lowerBound])
        buffer.removeSubrange(..<range.upperBound)
        insideCodeBlock.toggle()

        if !prefix.isEmpty {
            return (prefix, isThinking, false)
        }
        return extractNextSegment()
    }

    /// Acts on the earliest of a code fence, a think opener, or an orphaned closer
    /// outside code blocks and thinking. Only complete tokens strictly before any later
    /// token are actionable, so chunk framing cannot reorder fence-vs-think precedence —
    /// and an orphaned closer earlier in the buffer reclassifies before a later opener
    /// can swallow it, matching what a split stream inevitably does.
    private mutating func tryExtractEarliestOuterToken() -> Segment? {
        let fencePosition = buffer.range(of: "```")?.lowerBound
        let openerPosition = buffer.range(of: "<think>")?.lowerBound
        let closerPosition = buffer.range(of: "</think>")?.lowerBound

        if let fence = fencePosition,
           closerPosition.map({ fence < $0 }) ?? true,
           openerPosition.map({ fence < $0 }) ?? true
        {
            return tryExtractCodeBlock()
        }
        if let closer = closerPosition,
           openerPosition.map({ closer < $0 }) ?? true
        {
            return tryExtractOrphanCloser()
        }
        return tryExtractThinkTags()
    }

    /// Chooses between a complete code fence and a closing think tag while inside
    /// thinking. Think tags inside a code block are ignored, but a closer that appears
    /// before a fence still closes the thinking block before the fence is processed.
    private mutating func tryExtractEarliestThinkingToken() -> Segment? {
        let fencePosition = buffer.range(of: "```")?.lowerBound
        let closerPosition = buffer.range(of: "</think>")?.lowerBound

        if let fence = fencePosition, closerPosition.map({ fence < $0 }) ?? true {
            return tryExtractCodeBlock()
        }
        return tryExtractThinkTags()
    }

    /// Reclassifies everything before an orphaned `</think>` (one with no opener) as
    /// reasoning. Only called when no fence or opener starts earlier in the buffer.
    private mutating func tryExtractOrphanCloser() -> Segment? {
        guard let range = buffer.range(of: "</think>") else { return nil }
        let contentBeforeTag = String(buffer[..<range.lowerBound])
        buffer.removeSubrange(..<range.upperBound)
        return (contentBeforeTag, false, true)
    }

    /// Returns true if the buffer ends with a run of backticks. The run may still grow
    /// with the next chunk — or complete a fence only at the buffer end — so it is held
    /// rather than acted on (see `extractSegmentBeforePartialCodeDelimiter`).
    private func holdingPartialCodeDelimiter() -> Bool {
        buffer.last == "`"
    }

    /// Emits text before a trailing backtick run while holding the run itself. Acting on
    /// a fence that completes only at the buffer end would emit the fence as visible
    /// text in a split stream while the unsplit stream consumes it as a delimiter, so
    /// the run stays buffered until the next chunk decides it.
    private mutating func extractSegmentBeforePartialCodeDelimiter() -> Segment? {
        let runLength = buffer.reversed().prefix(while: { $0 == "`" }).count
        guard runLength > 0 else { return nil }
        let splitIndex = buffer.index(buffer.endIndex, offsetBy: -runLength)
        guard splitIndex > buffer.startIndex else { return nil }

        let suffix = String(buffer[splitIndex...])
        buffer = String(buffer[..<splitIndex])

        let result = extractNextSegment()
        buffer = buffer + suffix
        return result
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
    ///
    /// The hold extends leftward over adjacent backticks and angle brackets: they could
    /// complete a fence or tag spanning the held partial once later chunks arrive, so
    /// emitting them now would diverge from the unsplit stream.
    private mutating func tryHoldPartialTag(
        _ tag: String, asThinking: Bool
    ) -> Segment? {
        guard let start = buffer.lastIndex(of: "<") else { return nil }
        let suffix = buffer[start...]
        guard tag.hasPrefix(String(suffix)) else { return nil }

        var holdStart = start
        while holdStart > buffer.startIndex {
            let previous = buffer[buffer.index(before: holdStart)]
            guard previous == "`" || previous == "<" else { break }
            holdStart = buffer.index(before: holdStart)
        }

        if holdStart > buffer.startIndex {
            let text = String(buffer[..<holdStart])
            buffer = String(buffer[holdStart...])
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

    /// Finalizes the stream, emitting any held trailing input as literal text in the
    /// current channel. While streaming, ambiguous tails (partial tags, fences, markers)
    /// stay buffered so split and unsplit decodes converge; at end-of-stream there is no
    /// next chunk to disambiguate them, so they are emitted verbatim instead of dropped.
    mutating func finish() {
        if !buffer.isEmpty {
            if isThinking {
                thinking += buffer
            } else {
                content += buffer
            }
            buffer = ""
        }
    }
}
