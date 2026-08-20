import Foundation
import Testing
@testable import PKContracts

@Suite("Structured Output Decoder Tests")
struct StructuredOutputDecoderTests {
    private struct TagPayload: Decodable, Equatable {
        let tags: [String]
    }

    private struct NestedPayload: Decodable, Equatable {
        let name: String
        let count: Int
        let nested: Nested

        struct Nested: Decodable, Equatable {
            let active: Bool
            let values: [Int]
        }
    }

    private struct OptionalPayload: Decodable, Equatable {
        let required: String
        let optional: String?
    }

    // MARK: - Clean JSON

    @Test("Decodes clean JSON object")
    func decodesCleanJSONObject() throws {
        let decoded = try StructuredOutputDecoder.decode(
            TagPayload.self,
            from: #"{"tags":["swift","clean"]}"#
        )
        #expect(decoded == TagPayload(tags: ["swift", "clean"]))
    }

    @Test("Decodes JSON surrounded by whitespace")
    func decodesJSONSurroundedByWhitespace() throws {
        let payload = "\n\n  {\"tags\":[\"swift\",\"spaced\"]}  \n\n"
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        #expect(decoded == TagPayload(tags: ["swift", "spaced"]))
    }

    @Test("Decodes nested JSON objects")
    func decodesNestedJSONObject() throws {
        let payload = #"{"name":"item","count":3,"nested":{"active":true,"values":[1,2,3]}}"#
        let decoded = try StructuredOutputDecoder.decode(NestedPayload.self, from: payload)
        #expect(decoded == NestedPayload(
            name: "item",
            count: 3,
            nested: .init(active: true, values: [1, 2, 3])
        ))
    }

    // MARK: - Markdown fences

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

    @Test("Decodes fenced JSON with extra whitespace inside fence markers")
    func decodesFencedJSONWithExtraWhitespace() throws {
        let payload = """
        ``` json
        {"tags":["swift","whitespace"]}
        ```
        """
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        #expect(decoded == TagPayload(tags: ["swift", "whitespace"]))
    }

    @Test("Decodes fenced JSON with trailing prose after closing fence")
    func decodesFencedJSONWithTrailingProse() throws {
        let payload = """
        ```json
        {"tags":["swift","trailing"]}
        ```
        Hope this helps!
        """
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        #expect(decoded == TagPayload(tags: ["swift", "trailing"]))
    }

    @Test("Decodes first fenced block when multiple fences are present")
    func decodesFirstFencedBlockWhenMultipleFencesPresent() throws {
        let payload = """
        ```json
        {"tags":["swift","first"]}
        ```
        ```json
        {"tags":["swift","second"]}
        ```
        """
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        #expect(decoded == TagPayload(tags: ["swift", "first"]))
    }

    // MARK: - Partial and malformed recovery

    @Test("Throws on invalid JSON payloads")
    func throwsOnInvalidJSONPayloads() {
        #expect(throws: StructuredOutputDecodingError.self) {
            _ = try StructuredOutputDecoder.decode(TagPayload.self, from: "not json")
        }
    }

    @Test("Throws on empty payload")
    func throwsOnEmptyPayload() {
        #expect(throws: StructuredOutputDecodingError.self) {
            _ = try StructuredOutputDecoder.decode(TagPayload.self, from: "")
        }
    }

    @Test("Throws on whitespace-only payload")
    func throwsOnWhitespaceOnlyPayload() {
        #expect(throws: StructuredOutputDecodingError.self) {
            _ = try StructuredOutputDecoder.decode(TagPayload.self, from: "   \n\t  ")
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

    @Test("Recovers truncated object missing closing brace")
    func recoversTruncatedObjectMissingClosingBrace() throws {
        let payload = #"{"tags":["swift","truncated"]"#
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        #expect(decoded == TagPayload(tags: ["swift", "truncated"]))
    }

    @Test("Recovers truncated array missing closing bracket")
    func recoversTruncatedArrayMissingClosingBracket() throws {
        let payload = #"{"tags":["swift","incomplete""#
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        #expect(decoded == TagPayload(tags: ["swift", "incomplete"]))
    }

    @Test("Recovers payload with trailing comma")
    func recoversPayloadWithTrailingComma() throws {
        let payload = #"{"tags":["swift","comma"],}"#
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        #expect(decoded == TagPayload(tags: ["swift", "comma"]))
    }

    @Test("Throws on payload with unquoted object keys")
    func throwsOnUnquotedObjectKeys() {
        let payload = #"{tags:["swift","unquoted"]}"#
        #expect(throws: StructuredOutputDecodingError.self) {
            _ = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        }
    }

    @Test("Throws on payload with single quotes")
    func throwsOnSingleQuotes() {
        let payload = "{'tags':['swift','single']}"
        #expect(throws: StructuredOutputDecodingError.self) {
            _ = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        }
    }

    // MARK: - Escaping and encoding

    @Test("Decodes JSON with escaped characters")
    func decodesJSONWithEscapedCharacters() throws {
        let payload = #"{"tags":["swift","line\nbreak","tab\there","quote\"inside"]}"#
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        #expect(decoded == TagPayload(tags: ["swift", "line\nbreak", "tab\there", "quote\"inside"]))
    }

    @Test("Decodes JSON with unicode characters")
    func decodesJSONWithUnicodeCharacters() throws {
        let payload = #"{"tags":["swift","\u00e9\u00e0","\ud83d\ude00"]}"#.data(using: .utf8)!
        let string = String(data: payload, encoding: .utf8)!
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: string)
        #expect(decoded == TagPayload(tags: ["swift", "éà", "😀"]))
    }

    // MARK: - Optional values

    @Test("Decodes payload with optional value present")
    func decodesOptionalValuePresent() throws {
        let payload = #"{"required":"hello","optional":"world"}"#
        let decoded = try StructuredOutputDecoder.decode(OptionalPayload.self, from: payload)
        #expect(decoded == OptionalPayload(required: "hello", optional: "world"))
    }

    @Test("Decodes payload with optional value omitted")
    func decodesOptionalValueOmitted() throws {
        let payload = #"{"required":"hello"}"#
        let decoded = try StructuredOutputDecoder.decode(OptionalPayload.self, from: payload)
        #expect(decoded == OptionalPayload(required: "hello", optional: nil))
    }

    // MARK: - Prefix handling

    @Test("Throws when prose precedes the JSON object")
    func throwsWhenProsePrecedesJSONObject() {
        let payload = #"Here is the result: {"tags":["swift","leading"]}"#
        #expect(throws: StructuredOutputDecodingError.self) {
            _ = try StructuredOutputDecoder.decode(TagPayload.self, from: payload)
        }
    }

    @Test("Decodes JSON object with no array values")
    func decodesEmptyArrayValue() throws {
        let decoded = try StructuredOutputDecoder.decode(TagPayload.self, from: #"{"tags":[]}"#)
        #expect(decoded == TagPayload(tags: []))
    }

    @Test("Decodes empty object when payload allows empty")
    func decodesEmptyObject() throws {
        struct EmptyPayload: Decodable, Equatable {}
        let decoded = try StructuredOutputDecoder.decode(EmptyPayload.self, from: "{}")
        #expect(decoded == EmptyPayload())
    }
}
