import Foundation
import ErrorKit
import Logging

public enum StructuredOutputDecodingError: Error, Equatable {
    case invalidJSONPayload
    case decodingFailed(String)
}

public enum StructuredOutputDecoder {
    private static let logger = Logger.module(named: "structured-output-decoder")

    public static func decode<T: Decodable>(
        _ type: T.Type,
        from payload: String,
        decoder: JSONDecoder = SerializationUtils.jsonDecoder
    ) throws -> T {
        let cleaned = sanitize(payload)
        do {
            guard let data = cleaned.data(using: .utf8) else {
                throw StructuredOutputDecodingError.invalidJSONPayload
            }
            return try decoder.decode(type, from: data)
        } catch {
            do {
                let repaired = try LenientJSONParser.parse(cleaned)
                let data = try LenientJSONParser.jsonData(from: repaired.value)
                let decoded = try decoder.decode(type, from: data)
                if repaired.repaired {
                    let reason = ErrorKit.userFriendlyMessage(for: error)
                    let fallbackReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(describing: error)
                        : reason
                    logger.warning("Recovered structured output via lenient JSON repair after strict decode failed: \(fallbackReason)")
                }
                return decoded
            } catch {
                if error is DecodingError {
                    throw StructuredOutputDecodingError.decodingFailed(String(describing: error))
                }
                throw StructuredOutputDecodingError.invalidJSONPayload
            }
        }
    }

    public static func sanitize(_ payload: String) -> String {
        LenientJSONParser.sanitize(payload)
    }
}
