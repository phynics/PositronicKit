import Foundation
import PartialJSON

public enum LenientJSONParsingError: PKError, Equatable {
    case invalidJSONPayload
    case serializationFailed

    public var errorDomain: String {
        PKErrorDomain.shared
    }

    public var errorCode: Int {
        switch self {
        case .invalidJSONPayload: return 201
        case .serializationFailed: return 202
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .invalidJSONPayload:
            return "The JSON payload could not be parsed, even after lenient repair."
        case .serializationFailed:
            return "The repaired JSON value could not be serialized back to data."
        }
    }
}

public enum LenientJSONParser {
    public struct ParseResult: Sendable, Equatable {
        public let value: AnyCodable
        public let repaired: Bool

        public init(value: AnyCodable, repaired: Bool) {
            self.value = value
            self.repaired = repaired
        }
    }

    public static func sanitize(_ payload: String) -> String {
        var cleaned = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        if let fencedJSON = extractFencedJSON(from: cleaned) {
            return fencedJSON
        }

        if cleaned.hasPrefix("```json") {
            cleaned.removeFirst("```json".count)
        } else if cleaned.hasPrefix("```") {
            cleaned.removeFirst(3)
        }

        if cleaned.hasSuffix("```") {
            cleaned.removeLast(3)
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parse(_ payload: String, sanitizeCodeFences: Bool = false) throws -> ParseResult {
        let cleaned = sanitizeCodeFences ? sanitize(payload) : payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw LenientJSONParsingError.invalidJSONPayload
        }

        if let strictValue = try? strictJSONObject(from: cleaned) {
            return ParseResult(value: AnyCodable(strictValue), repaired: false)
        }

        do {
            let repairedValue = try PartialJSON.parse(cleaned, options: .all)
            return ParseResult(value: AnyCodable(repairedValue), repaired: true)
        } catch {
            throw LenientJSONParsingError.invalidJSONPayload
        }
    }

    public static func jsonData(from value: AnyCodable) throws -> Data {
        let encoder = JSONEncoder()
        do {
            return try encoder.encode(value)
        } catch {
            throw LenientJSONParsingError.serializationFailed
        }
    }

    private static func strictJSONObject(from payload: String) throws -> Any {
        guard let data = payload.data(using: .utf8) else {
            throw LenientJSONParsingError.invalidJSONPayload
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func extractFencedJSON(from payload: String) -> String? {
        guard let fence = payload.range(of: "```") else { return nil }

        let afterFence = payload[fence.upperBound...]
        guard let metadataEnd = afterFence.firstIndex(of: "\n") else { return nil }

        let metadata = afterFence[..<metadataEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard metadata.isEmpty || metadata.caseInsensitiveCompare("json") == .orderedSame else {
            return nil
        }

        let bodyStart = afterFence.index(after: metadataEnd)
        let bodyAndRemainder = afterFence[bodyStart...]
        let body = bodyAndRemainder.range(of: "```")
            .map { bodyAndRemainder[..<$0.lowerBound] }
            ?? bodyAndRemainder[...]

        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
