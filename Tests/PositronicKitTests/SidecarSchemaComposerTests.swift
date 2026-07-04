import Foundation
import JSONSchemaBuilder
import struct JSONSchema.Schema
import PKShared
@testable import PositronicKit
import Testing

struct SidecarSchemaComposerTests {
    private let title = SidecarDirective(
        name: "title", instruction: "Short title; null to decline.",
        schema: JSONString().definition(), streaming: .buffered
    )
    private let tone = SidecarDirective(
        name: "tone", instruction: "One-word tone.",
        schema: JSONString().definition(), streaming: .buffered
    )

    @Test func composesNestedSidecarPayloadWithStableRootKeyOrder() throws {
        let request = try SidecarSchemaComposer.compose(directives: [title, tone])
        guard case let .jsonSchema(schema) = request else {
            Issue.record("expected .jsonSchema")
            return
        }
        #expect(schema.strict)
        let encoded = try encodedSchemaString(schema.schema)
        let rootSection = try #require(rootPropertiesSection(in: encoded))
        #expect(rootSection.contains(#""response""#))
        #expect(rootSection.contains(#""sidecar_payload""#))
        let responseIndex = try #require(rootSection.range(of: #""response""#)?.lowerBound)
        let sidecarIndex = try #require(rootSection.range(of: #""sidecar_payload""#)?.lowerBound)
        #expect(responseIndex < sidecarIndex)
        #expect(encoded.contains(#""priority_sidecar_payload""#) == false)

        let repeated = try (0..<20).map { _ in
            try #require(rootPropertiesSignature(in: encodedSchemaString(schema.schema)))
        }
        #expect(Set(repeated).count == 1)
        #expect(repeated.first == "response<sidecar_payload")
    }

    @Test func duplicateNamesThrow() {
        #expect(throws: SidecarError.self) {
            _ = try SidecarSchemaComposer.compose(directives: [title, title])
        }
    }

    @Test func reservedNameThrows() {
        let bad = SidecarDirective(
            name: "response", instruction: "x", schema: JSONString().definition(), streaming: .buffered
        )
        #expect(throws: SidecarError.self) {
            _ = try SidecarSchemaComposer.compose(directives: [bad])
        }
    }

    @Test func instructionBlockListsEveryDirective() {
        let block = SidecarSchemaComposer.instructionBlock(directives: [title, tone])
        #expect(block.contains("title"))
        #expect(block.contains("Short title; null to decline."))
        #expect(block.contains("tone"))
        #expect(block.contains("response"))
        #expect(block.contains("sidecar_payload"))
    }

    private func encodedSchemaString(_ schema: Schema) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(schema), as: UTF8.self)
    }

    private func rootPropertiesSection(in encoded: String) -> String? {
        guard let start = encoded.range(of: #""properties":{"#)?.upperBound else {
            return nil
        }
        return String(encoded[start...])
    }

    private func rootPropertiesSignature(in encoded: String) -> String? {
        guard let section = rootPropertiesSection(in: encoded),
              let responseIndex = section.range(of: #""response""#)?.lowerBound,
              let sidecarIndex = section.range(of: #""sidecar_payload""#)?.lowerBound else {
            return nil
        }
        return responseIndex < sidecarIndex ? "response<sidecar_payload" : "sidecar_payload<response"
    }
}
