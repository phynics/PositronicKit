import Foundation
import Testing
@testable import PKShared

@Suite("Structured Output Decoder Tests")
struct StructuredOutputDecoderTests {
    private struct TagPayload: Decodable, Equatable {
        let tags: [String]
    }

    @Test("Decodes fenced JSON payloads")
    func decodesFencedJSONPayloads() throws {
        let payload = """
        ```json
        {"tags":["swift","json"]}
        ```
        """

        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)

        #expect(decoded == TagPayload(tags: ["swift", "json"]))
    }

    @Test("Throws on invalid JSON payloads")
    func throwsOnInvalidJSONPayloads() {
        #expect(throws: StructuredOutputDecodingError.self) {
            _ = try StructuredOutputDecoder.decode(TagPayload.self, from: "not json")
        }
    }
}
