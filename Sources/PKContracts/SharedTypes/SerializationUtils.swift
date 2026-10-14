import Foundation

/// Shared `JSONEncoder`/`JSONDecoder` instances with consistent date handling, for callers
/// that need to encode or decode without hand-rolling a configured coder.
@usableFromInline
package enum SerializationUtils {
    /// A `JSONEncoder` configured to encode `Date` as ISO 8601.
    @usableFromInline
    package static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// A `JSONDecoder` configured to decode `Date` as ISO 8601.
    @usableFromInline
    package static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
