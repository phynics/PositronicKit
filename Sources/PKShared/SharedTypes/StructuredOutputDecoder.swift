import Foundation

public enum StructuredOutputDecodingError: Error, Equatable {
    case invalidJSONPayload
    case decodingFailed(String)
}

public enum StructuredOutputDecoder {
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from payload: String,
        decoder: JSONDecoder = SerializationUtils.jsonDecoder
    ) throws -> T {
        let cleaned = sanitize(payload)
        guard let data = cleaned.data(using: .utf8) else {
            throw StructuredOutputDecodingError.invalidJSONPayload
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            if error is DecodingError {
                throw StructuredOutputDecodingError.decodingFailed(String(describing: error))
            }
            throw StructuredOutputDecodingError.invalidJSONPayload
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
