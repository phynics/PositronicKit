import PKShared
import Foundation

/// Heuristic token estimation shared across prompt assembly and runtime code.
///
/// The estimator is intentionally lightweight and deterministic. It follows a
/// tokenx-style segmented heuristic rather than a flat character-count rule so
/// punctuation, numeric runs, and CJK text are treated more realistically.
public enum TokenEstimator {
    private static let defaultCharsPerToken = 6.0
    private static let shortTokenThreshold = 3
    private static let punctuationScalars = CharacterSet(charactersIn: #".,!?;(){}[]<>:/\|@#$%^&*+=`~_-"#)
    private static let compactLatinScalars = CharacterSet(charactersIn: "äöüßÄÖÜẞéèêëàâîïôûùüÿçœæáíóúñąćęłńóśźżěščřžýůúďťň")

    public static func estimate(text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var tokenCount = 0
        for segment in segments(in: text) {
            tokenCount += estimate(segment: segment)
        }
        return tokenCount
    }

    public static func estimate(parts: [String]) -> Int {
        estimate(text: parts.joined(separator: " "))
    }

    private static func segments(in text: String) -> [Substring] {
        var segments: [Substring] = []
        var segmentStart = text.startIndex
        var previousKind: SegmentKind?
        var index = text.startIndex

        while index < text.endIndex {
            let kind = classify(text[index])
            if let previousKind, previousKind != kind {
                segments.append(text[segmentStart..<index])
                segmentStart = index
            }
            previousKind = kind
            index = text.index(after: index)
        }

        if segmentStart < text.endIndex {
            segments.append(text[segmentStart..<text.endIndex])
        }

        return segments
    }

    private static func estimate(segment: Substring) -> Int {
        guard !segment.isEmpty else { return 0 }
        if isWhitespace(segment) { return 0 }
        if containsCJK(segment) { return segment.count }
        if isNumericRun(segment) { return 1 }
        if segment.count <= shortTokenThreshold { return 1 }
        if isPunctuation(segment) { return max(1, Int(ceil(Double(segment.count) / 2.0))) }

        let charsPerToken = containsCompactLatin(segment) ? 3.5 : defaultCharsPerToken
        return max(1, Int(ceil(Double(segment.count) / charsPerToken)))
    }

    private static func classify(_ character: Character) -> SegmentKind {
        if character.isWhitespace {
            return .whitespace
        }
        if isPunctuation(character) {
            return .punctuation
        }
        return .text
    }

    private static func isWhitespace(_ segment: Substring) -> Bool {
        segment.allSatisfy(\.isWhitespace)
    }

    private static func isNumericRun(_ segment: Substring) -> Bool {
        var sawDigit = false
        for scalar in segment.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                sawDigit = true
                continue
            }
            if scalar == "." || scalar == "," {
                continue
            }
            return false
        }
        return sawDigit
    }

    private static func isPunctuation(_ segment: Substring) -> Bool {
        segment.allSatisfy(isPunctuation)
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { punctuationScalars.contains($0) }
    }

    private static func containsCompactLatin(_ segment: Substring) -> Bool {
        segment.unicodeScalars.contains { compactLatinScalars.contains($0) }
    }

    private static func containsCJK(_ segment: Substring) -> Bool {
        segment.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value)
                || (0x3000...0x303F).contains(value)
                || (0xFF00...0xFFEF).contains(value)
                || (0x30A0...0x30FF).contains(value)
                || (0x2E80...0x2EFF).contains(value)
                || (0x31C0...0x31EF).contains(value)
                || (0x3200...0x32FF).contains(value)
                || (0x3300...0x33FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
                || (0x1100...0x11FF).contains(value)
                || (0x3130...0x318F).contains(value)
                || (0xA960...0xA97F).contains(value)
                || (0xD7B0...0xD7FF).contains(value)
        }
    }

    private enum SegmentKind {
        case whitespace
        case punctuation
        case text
    }
}
