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

    @Test("Decodes uppercase and generic fenced JSON payloads")
    func decodesAlternateFenceFormats() throws {
        let uppercaseFence = """
        ```JSON
        {"tags":["swift","uppercase"]}
        ```
        """
        let genericFence = """
        ```
        {"tags":["swift","generic"]}
        ```
        """

        #expect(try StructuredOutputDecoder.decode(TagPayload.self, from: uppercaseFence) == TagPayload(tags: ["swift", "uppercase"]))
        #expect(try StructuredOutputDecoder.decode(TagPayload.self, from: genericFence) == TagPayload(tags: ["swift", "generic"]))
    }

    @Test("Decodes fenced JSON payloads surrounded by prose")
    func decodesFencedJSONPayloadsSurroundedByProse() throws {
        let payload = """
        Here is the structured response:
        ```json
        {"tags":["swift","prose"]}
        ```
        """

        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)

        #expect(decoded == TagPayload(tags: ["swift", "prose"]))
    }

    @Test("Throws on invalid JSON payloads")
    func throwsOnInvalidJSONPayloads() {
        #expect(throws: StructuredOutputDecodingError.self) {
            _ = try StructuredOutputDecoder.decode(TagPayload.self, from: "not json")
        }
    }

    @Test("Recovers truncated fenced JSON payloads")
    func recoversTruncatedFencedJSONPayloads() throws {
        let payload = """
        ```json
        {"tags":["swift","repair"]
        ```
        """

        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)

        #expect(decoded == TagPayload(tags: ["swift", "repair"]))
    }

    @Test("Recovers payloads with trailing garbage")
    func recoversPayloadsWithTrailingGarbage() throws {
        let payload = #"{"tags":["swift","tail"]} trailing"#

        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)

        #expect(decoded == TagPayload(tags: ["swift", "tail"]))
    }
}
