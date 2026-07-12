import ErrorKit
import Foundation
import Logging

/// Errors surfaced when a structured-output payload can't be turned into the requested type,
/// even after lenient JSON repair.
public enum StructuredOutputDecodingError: Error, Equatable {
    /// The payload could not be parsed as JSON at all (not even after repair).
    case invalidJSONPayload
    /// The payload parsed as JSON but didn't match the requested `Decodable` type; the
    /// associated string carries the underlying decoding error's description.
    case decodingFailed(String)
}

/// Decodes structured-output payloads returned by the model, tolerating minor JSON
/// malformation that LLMs commonly produce.
public enum StructuredOutputDecoder {
    private static let logger = Logger(label: "com.positronickit.structured-output-decoder")

    /// Decodes `payload` as `type`, first attempting strict JSON decoding and falling back
    /// to ``LenientJSONParser`` repair (e.g. trailing commas, unquoted keys) if that fails.
    /// A successful repair is logged at `warning` level.
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

    /// Strips common wrapper artifacts (e.g. markdown code fences) from a raw payload before decoding.
    public static func sanitize(_ payload: String) -> String {
        LenientJSONParser.sanitize(payload)
    }
}
