import MonadShared
import Foundation
import NaturalLanguage

/// Utility for token estimation using NaturalLanguage tokenizer
public enum TokenEstimator {
    /// Estimate tokens for a string using NLTokenizer
    /// Falls back to char/4 if NLTokenizer is slow or unavailable, but here we assume availability.
    /// This is closer to real BPE than char/4.
    public static func estimate(text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }

        // Words are not 1:1 with tokens. Common words are 1 token, complex are multiple.
        // A common multiplier is 1.3 tokens per word for English.
        // For code, it varies.
        // Let's refine:
        // NLTokenizer doesn't count punctuation well as "words".
        // Regex might be faster and sufficient.
        // Standard rule: 1 token ~= 4 chars in English. 1 token ~= ¾ words.
        // So tokens = words * (4/3) = words * 1.33

        return Int(Double(count) * 1.33)
    }

    /// Estimate tokens for multiple components
    ///
    /// - Note: Batches token estimation by joining components first.
    /// This reduces the overhead of tokenizer initialization from O(N) to O(1),
    /// which is significant when estimating many small strings (e.g. chat history).
    public static func estimate(parts: [String]) -> Int {
        let combined = parts.joined(separator: " ")
        return estimate(text: combined)
    }
}
