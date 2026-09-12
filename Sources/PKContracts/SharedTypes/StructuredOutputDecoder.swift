import ErrorKit
import Foundation
import Logging

/// Errors surfaced when a structured-output payload can't be turned into the requested type,
/// even after lenient JSON repair.
public enum StructuredOutputDecodingError: PKError, Sendable, Equatable {
    /// The payload could not be parsed as JSON at all (not even after repair).
    case invalidJSONPayload
    /// The payload parsed as JSON but didn't match the requested `Decodable` type; the
    /// associated string carries the underlying decoding error's description.
    case decodingFailed(String)

    public var errorDomain: String {
        PKErrorDomain.shared
    }

    public var errorCode: Int {
        switch self {
        case .invalidJSONPayload: return 203
        case .decodingFailed: return 204
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .invalidJSONPayload:
            return "The model response was not valid JSON, even after repair. Ask the model to return only the requested JSON object."
        case let .decodingFailed(reason):
            return "The model returned valid JSON, but it did not match the requested type: \(reason)"
        }
    }

    public var remediation: String? {
        switch self {
        case .invalidJSONPayload:
            return "Retry with a prompt that requests only JSON matching the structured-output schema, and confirm the provider supports structured output."
        case .decodingFailed:
            return "Ensure the schema keys match the decoder's CodingKeys or key-decoding strategy, then retry."
        }
    }
}

/// Decodes structured-output payloads returned by the model, tolerating minor JSON
/// malformation that LLMs commonly produce.
public enum StructuredOutputDecoder {
    private static let logger = Logger(label: "com.positronickit.structured-output-decoder")

    /// Decodes `payload` as `type`, first checking strict JSON syntax and falling back to
    /// ``LenientJSONParser`` repair (e.g. trailing commas, unquoted keys) if that fails. A
    /// successful repair is logged at `warning` level. The type decoder runs exactly once after
    /// the payload has been parsed, so custom decoding failures cannot be mistaken for malformed
    /// JSON or executed a second time.
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from payload: String,
        decoder: JSONDecoder = SerializationUtils.jsonDecoder
    ) throws -> T {
        let cleaned = sanitize(payload)
        guard let strictData = cleaned.data(using: .utf8) else {
            throw StructuredOutputDecodingError.invalidJSONPayload
        }

        let data: Data
        let wasRepaired: Bool
        if (try? JSONSerialization.jsonObject(with: strictData, options: [.fragmentsAllowed])) != nil {
            data = strictData
            wasRepaired = false
        } else {
            do {
                let repaired = try LenientJSONParser.parse(cleaned)
                data = try LenientJSONParser.jsonData(from: repaired.value)
                wasRepaired = repaired.wasRepaired
            } catch {
                throw StructuredOutputDecodingError.invalidJSONPayload
            }
        }

        do {
            let decoded = try decoder.decode(type, from: data)
            if wasRepaired {
                logger.warning("Recovered structured output via lenient JSON repair")
            }
            return decoded
        } catch {
            let reason = ErrorKit.userFriendlyMessage(for: error)
            let fallbackReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(describing: error)
                : reason
            throw StructuredOutputDecodingError.decodingFailed(fallbackReason)
        }
    }

    /// Strips common wrapper artifacts (e.g. markdown code fences) from a raw payload before decoding.
    public static func sanitize(_ payload: String) -> String {
        LenientJSONParser.sanitize(payload)
    }
}
