import Foundation
@testable import PKShared
import Testing

/// Coverage for `LenientJSONParser` — the lenient JSON repair pipeline used to parse
/// LLM-emitted JSON that may be malformed, truncated, or wrapped in code fences.
///
/// This is load-bearing code: it's the fallback parser for tool-call argument extraction
/// and structured-output decoding. It had zero direct coverage.
@Suite("LenientJSONParser")
struct LenientJSONParserTests {

    // MARK: - sanitize

    @Test("sanitize strips ```json fences")
    func sanitizeStripsJsonFences() {
        let input = "```json\n{\"key\":\"value\"}\n```"
        let result = LenientJSONParser.sanitize(input)
        #expect(result == "{\"key\":\"value\"}")
    }

    @Test("sanitize strips bare ``` fences")
    func sanitizeStripsBareFences() {
        let input = "```\n{\"key\":\"value\"}\n```"
        let result = LenientJSONParser.sanitize(input)
        #expect(result == "{\"key\":\"value\"}")
    }

    @Test("sanitize extracts fenced JSON from surrounding text")
    func sanitizeExtractsFencedJSON() {
        let input = "Here is the result:\n```json\n{\"a\":1}\n```\nDone."
        let result = LenientJSONParser.sanitize(input)
        #expect(result == "{\"a\":1}")
    }

    @Test("sanitize extracts bare-fenced JSON from surrounding text")
    func sanitizeExtractsBareFencedJSON() {
        let input = "Result:\n```\n{\"a\":1}\n```\nEnd"
        let result = LenientJSONParser.sanitize(input)
        #expect(result == "{\"a\":1}")
    }

    @Test("sanitize handles fenced JSON with no closing fence")
    func sanitizeFencedNoClosing() {
        let input = "```json\n{\"a\":1}"
        let result = LenientJSONParser.sanitize(input)
        #expect(result == "{\"a\":1}")
    }

    @Test("sanitize returns trimmed input when no fences present")
    func sanitizeNoFences() {
        let input = "  {\"key\":\"value\"}  "
        let result = LenientJSONParser.sanitize(input)
        #expect(result == "{\"key\":\"value\"}")
    }

    @Test("sanitize ignores non-json fenced content")
    func sanitizeNonJsonFence() {
        let input = "```python\nprint('hello')\n```"
        let result = LenientJSONParser.sanitize(input)
        // The fence metadata "python" is not "json", so the fence is not extracted;
        // the bare ``` prefix/suffix stripping still applies.
        #expect(!result.contains("```"))
    }

    @Test("sanitize handles empty fence metadata")
    func sanitizeEmptyFenceMetadata() {
        let input = "```\n{\"a\":1}\n```"
        let result = LenientJSONParser.sanitize(input)
        #expect(result == "{\"a\":1}")
    }

    // MARK: - parse

    @Test("parse returns strict value without repair for valid JSON")
    func parseValidJSONNoRepair() throws {
        let result = try LenientJSONParser.parse("{\"key\":\"value\"}")
        #expect(result.repaired == false)
        if case let .dictionary(dict) = result.value {
            if case let .string(str) = dict["key"] ?? .null {
                #expect(str == "value")
            } else {
                Issue.record("Expected string value")
            }
        } else {
            Issue.record("Expected dictionary")
        }
    }

    @Test("parse repairs truncated JSON via PartialJSON")
    func parseRepairsTruncatedJSON() throws {
        // Truncated JSON — PartialJSON should repair it.
        let result = try LenientJSONParser.parse("{\"key\":\"value\",\"nested\":{\"a\":1")
        #expect(result.repaired == true)
    }

    @Test("parse sanitizes code fences when sanitizeCodeFences is true")
    func parseWithCodeFenceSanitization() throws {
        let result = try LenientJSONParser.parse("```json\n{\"key\":\"value\"}\n```", sanitizeCodeFences: true)
        #expect(result.repaired == false)
        if case let .dictionary(dict) = result.value {
            if case let .string(str) = dict["key"] ?? .null {
                #expect(str == "value")
            } else {
                Issue.record("Expected string value")
            }
        } else {
            Issue.record("Expected dictionary")
        }
    }

    @Test("parse throws for empty input")
    func parseEmptyThrows() {
        #expect(throws: LenientJSONParsingError.invalidJSONPayload) {
            try LenientJSONParser.parse("")
        }
    }

    @Test("parse throws for whitespace-only input")
    func parseWhitespaceThrows() {
        #expect(throws: LenientJSONParsingError.invalidJSONPayload) {
            try LenientJSONParser.parse("   \n  ")
        }
    }

    @Test("parse throws for completely invalid input")
    func parseInvalidThrows() {
        #expect(throws: LenientJSONParsingError.invalidJSONPayload) {
            try LenientJSONParser.parse("not json at all")
        }
    }

    @Test("parse handles JSON array fragments")
    func parseArrayFragment() throws {
        let result = try LenientJSONParser.parse("[1, 2, 3]")
        #expect(result.repaired == false)
    }

    @Test("parse handles JSON value fragments")
    func parseValueFragment() throws {
        let result = try LenientJSONParser.parse("\"hello\"")
        #expect(result.repaired == false)
    }

    // MARK: - jsonData

    @Test("jsonData encodes AnyCodable to Data")
    func jsonDataEncodes() throws {
        let value = AnyCodable(["key": "value"])
        let data = try LenientJSONParser.jsonData(from: value)
        #expect(!data.isEmpty)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["key"] as? String == "value")
    }

    // MARK: - LenientJSONParsingError

    @Test("LenientJSONParsingError has correct domain and codes")
    func errorDomainAndCodes() {
        #expect(LenientJSONParsingError.invalidJSONPayload.errorDomain == PKErrorDomain.shared)
        #expect(LenientJSONParsingError.invalidJSONPayload.errorCode == 201)
        #expect(LenientJSONParsingError.serializationFailed.errorDomain == PKErrorDomain.shared)
        #expect(LenientJSONParsingError.serializationFailed.errorCode == 202)
    }

    @Test("LenientJSONParsingError userFriendlyMessage is descriptive")
    func errorMessages() {
        #expect(LenientJSONParsingError.invalidJSONPayload.userFriendlyMessage.contains("parsed"))
        #expect(LenientJSONParsingError.serializationFailed.userFriendlyMessage.contains("serialized"))
    }

    @Test("LenientJSONParsingError is Equatable")
    func errorEquatable() {
        #expect(LenientJSONParsingError.invalidJSONPayload == .invalidJSONPayload)
        #expect(LenientJSONParsingError.invalidJSONPayload != .serializationFailed)
    }
}
