import Foundation

/// Utility for parsing LLM responses
public enum MessageParser {
    /// Parse LLM response and extract thinking tags
    ///
    /// Extracts Chain of Thought reasoning from `<think>...</think>` blocks.
    /// Supported by models like:
    /// - DeepSeek R1
    /// - QwQ (Alibaba)
    /// - Other reasoning models
    ///
    /// Example input:
    /// ```
    /// <think>Let me break this down step by step...</think>
    /// The answer is 42.
    /// ```
    ///
    /// Example output:
    /// ```
    /// content: "The answer is 42."
    /// think: "Let me break this down step by step..."
    /// ```
    ///
    /// - Parameter rawResponse: Raw response from LLM
    /// - Returns: Tuple with content and optional thinking
    public static func parseResponse(_ rawResponse: String) -> (content: String, think: String?) {
        // Pattern to match <think>...</think> tags
        let pattern = "<think>(.*?)</think>"

        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: .dotMatchesLineSeparators
            )
        else {
            return (rawResponse, nil)
        }

        let nsString = rawResponse as NSString
        let matches = regex.matches(
            in: rawResponse, range: NSRange(location: 0, length: nsString.length)
        )

        // Extract thinking content
        var thinkingText: String?
        if let match = matches.first, match.numberOfRanges > 1 {
            let thinkRange = match.range(at: 1)
            thinkingText = nsString.substring(with: thinkRange).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }

        // Remove all <think>...</think> blocks from content
        let cleanContent = regex.stringByReplacingMatches(
            in: rawResponse,
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleanContent, thinkingText)
    }

    /// Clean content for UI display (removes <tool_call> tags)
    /// - Parameter content: The raw content string
    /// - Returns: Cleaned string ready for display
    public static func displayContent(for content: String) -> String {
        // Pattern to match <tool_call>...</tool_call> tags, optionally wrapped in code blocks
        let pattern = "(?:```(?:xml)?\\s*)?<tool_call>(.*?)</tool_call>(?:\\s*```)?"

        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]
            )
        else {
            return content
        }

        let nsString = content as NSString
        return regex.stringByReplacingMatches(
            in: content,
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: ""
        ).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}
