import Foundation
import JSONSchemaBuilder
import struct JSONSchema.Schema
import PKShared
@testable import PositronicKit
import Testing

@Schemable
struct OptionalTitlePayload: Codable, Equatable {
    let title: String?
}

@Schemable
struct RequiredTitlePayload: Codable, Equatable {
    let title: String
}

struct SidecarOutcomeContractTests {
    private func makeExtractor(
        directives: [SidecarDirective]
    ) -> SidecarStreamExtractor {
        SidecarStreamExtractor(directives: directives)
    }

    private func run(_ chunks: [String], extractor: inout SidecarStreamExtractor) -> [SidecarStreamExtractor.Output] {
        var outputs: [SidecarStreamExtractor.Output] = []
        for chunk in chunks {
            outputs += extractor.consume(chunk)
        }
        outputs += extractor.finish()
        return outputs
    }

    private func completedResults(_ outputs: [SidecarStreamExtractor.Output]) -> [SidecarResult] {
        outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
    }

    @Test func leafStringDirectiveEmitsStringScalarValue() {
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
        ])
        let outputs = run(
            [#"{"response": "ok", "sidecar_payload": {"title": "Hello"}}"#],
            extractor: &extractor
        )
        let results = completedResults(outputs)
        #expect(results.count == 1)
        #expect(results[0].name == "title")

        guard case let .value(anyCodable) = results[0].outcome else {
            Issue.record("expected .value outcome, got \(results[0].outcome)")
            return
        }
        #expect(anyCodable == .string("Hello"))
        #expect(anyCodable.asString == "Hello")
        #expect(anyCodable.asDictionary == nil)
    }

    @Test func objectSchemaDirectiveEmitsDictionaryValue() {
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: RequiredTitlePayload.schema.definition(), streaming: .buffered),
        ])
        let outputs = run(
            [#"{"response": "ok", "sidecar_payload": {"title": {"title": "Hello"}}}"#],
            extractor: &extractor
        )
        let results = completedResults(outputs)
        #expect(results.count == 1)
        #expect(results[0].name == "title")

        guard case let .value(anyCodable) = results[0].outcome else {
            Issue.record("expected .value outcome, got \(results[0].outcome)")
            return
        }
        #expect(anyCodable == .dictionary(["title": .string("Hello")]))
        #expect(anyCodable.asString == nil)
        #expect(anyCodable.asDictionary == ["title": .string("Hello")])
    }

    @Test func nullValueYieldsDeclinedNotValueNull() {
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
        ])
        let outputs = run(
            [#"{"response": "ok", "sidecar_payload": {"title": null}}"#],
            extractor: &extractor
        )
        let results = completedResults(outputs)
        #expect(results == [SidecarResult(name: "title", outcome: .declined)])
    }

    @Test func missingKeyYieldsFailedAtStreamEnd() {
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
        ])
        let outputs = run(
            [#"{"response": "ok", "sidecar_payload": {}}"#],
            extractor: &extractor
        )
        let results = completedResults(outputs)
        #expect(results == [SidecarResult(name: "title", outcome: .failed(reason: "field missing at stream end"))])
    }

    @Test func wrongSidecarKeyYieldsFailed() {
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
        ])
        let outputs = run(
            [#"{"response": "ok", "sidecar_payload": {"text": "Hello"}}"#],
            extractor: &extractor
        )
        let results = completedResults(outputs)
        #expect(results == [SidecarResult(name: "title", outcome: .failed(reason: "field missing at stream end"))])
    }

    @Test func sidecarResultCodableRoundTripsPreservingStringCase() throws {
        let original = SidecarResult(name: "title", outcome: .value(.string("Hello")))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SidecarResult.self, from: data)
        #expect(decoded == original)
        guard case let .value(anyCodable) = decoded.outcome else {
            Issue.record("expected .value outcome")
            return
        }
        #expect(anyCodable == .string("Hello"))
        #expect(anyCodable.asString == "Hello")
        #expect(anyCodable.asDictionary == nil)
    }

    @Test func sidecarResultCodableRoundTripsPreservingDictionaryCase() throws {
        let original = SidecarResult(name: "title", outcome: .value(.dictionary(["title": .string("Hello")])))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SidecarResult.self, from: data)
        #expect(decoded == original)
        guard case let .value(anyCodable) = decoded.outcome else {
            Issue.record("expected .value outcome")
            return
        }
        #expect(anyCodable == .dictionary(["title": .string("Hello")]))
        #expect(anyCodable.asString == nil)
        #expect(anyCodable.asDictionary == ["title": .string("Hello")])
    }

    @Test func sidecarResultCodableRoundTripsDeclinedAndFailed() throws {
        let declined = SidecarResult(name: "title", outcome: .declined)
        let declinedData = try JSONEncoder().encode(declined)
        let declinedDecoded = try JSONDecoder().decode(SidecarResult.self, from: declinedData)
        #expect(declinedDecoded == declined)

        let failed = SidecarResult(name: "title", outcome: .failed(reason: "field missing at stream end"))
        let failedData = try JSONEncoder().encode(failed)
        let failedDecoded = try JSONDecoder().decode(SidecarResult.self, from: failedData)
        #expect(failedDecoded == failed)
    }

    // MARK: - Strict-mode investigation (PKTEST-1)
    //
    // OpenAI strict-JSON-schema mode requires every property to be listed in `required`;
    // optionals must additionally use `type: ["string", "null"]`. `@Schemable` emits the
    // nullable union correctly but omits the `required` array entirely when all fields are
    // optional. `SidecarSchemaComposer.compose` sets `strict: true` unconditionally, so a
    // directive whose payload has only optional fields produces a schema that violates
    // OpenAI strict-mode rules. The provider silently degrades and the model may freelance
    // off-schema keys (observed in production: Yakamoz SID-3). Follow-up fix needed in PK.

    @Test func strictModeWithOptionalPayloadField_omitsFromRequired() throws {
        let directive = SidecarDirective(
            name: "title",
            instruction: "t",
            schema: OptionalTitlePayload.schema.definition(),
            streaming: .buffered
        )
        let request = try SidecarSchemaComposer.compose(directives: [directive])
        guard case let .jsonSchema(schema) = request else {
            Issue.record("expected .jsonSchema")
            return
        }
        #expect(schema.strict)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(decoding: try encoder.encode(schema.schema), as: UTF8.self)

        let sidecarPayloadSection = try #require(extractSidecarPayloadProperties(in: encoded))
        let titlePropertySchema = try #require(extractPropertySchema(named: "title", from: sidecarPayloadSection))

        #expect(titlePropertySchema.contains(#""type":"object""#))
        #expect(titlePropertySchema.contains(#""type":["string","null"]"#))

        let innerRequired = extractRequiredArray(from: titlePropertySchema)
        #expect(innerRequired == nil || !innerRequired!.contains("\"title\""))
    }

    @Test func strictModeWithRequiredPayloadField_includesInRequired() throws {
        let directive = SidecarDirective(
            name: "title",
            instruction: "t",
            schema: RequiredTitlePayload.schema.definition(),
            streaming: .buffered
        )
        let request = try SidecarSchemaComposer.compose(directives: [directive])
        guard case let .jsonSchema(schema) = request else {
            Issue.record("expected .jsonSchema")
            return
        }
        #expect(schema.strict)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(decoding: try encoder.encode(schema.schema), as: UTF8.self)

        let sidecarPayloadSection = try #require(extractSidecarPayloadProperties(in: encoded))
        let titlePropertySchema = try #require(extractPropertySchema(named: "title", from: sidecarPayloadSection))

        #expect(titlePropertySchema.contains(#""type":"object""#))

        let innerRequired = try #require(extractRequiredArray(from: titlePropertySchema))
        #expect(innerRequired.contains("\"title\""))
    }

    // MARK: - Schema JSON extraction helpers

    private func extractSidecarPayloadProperties(in encoded: String) -> String? {
        guard let range = encoded.range(of: #""sidecar_payload":"#) else { return nil }
        return String(encoded[range.upperBound...])
    }

    private func extractPropertySchema(named name: String, from section: String) -> String? {
        let key = #""\#(name)":"#
        guard let start = section.range(of: key)?.upperBound else { return nil }
        var depth = 0
        var index = start
        var inString = false
        var escaped = false
        for char in section[start...] {
            if escaped { escaped = false; index = section.index(after: index); continue }
            switch char {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "{" where !inString: depth += 1
            case "}" where !inString:
                depth -= 1
                if depth == 0 {
                    return String(section[start...index])
                }
            default: break
            }
            index = section.index(after: index)
        }
        return nil
    }

    private func extractRequiredArray(from objectSchema: String) -> String? {
        guard let range = objectSchema.range(of: #""required":"#) else { return nil }
        let after = objectSchema[range.upperBound...]
        guard let openBracket = after.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for (idx, char) in after[openBracket...].enumerated() {
            if escaped { escaped = false; continue }
            switch char {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "[" where !inString: depth += 1
            case "]" where !inString:
                depth -= 1
                if depth == 0 {
                    let end = after.index(openBracket, offsetBy: idx + 1)
                    return String(after[openBracket..<end])
                }
            default: break
            }
        }
        return nil
    }
}
