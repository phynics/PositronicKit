import Foundation
import JSONSchemaBuilder
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

    @Test func composesResponseAndDirectivesWithAllFieldsRequired() throws {
        let request = try SidecarSchemaComposer.compose(directives: [title, tone])
        guard case let .jsonSchema(schema) = request else {
            Issue.record("expected .jsonSchema")
            return
        }
        #expect(schema.strict)
        let encoded = try JSONEncoder().encode(schema.schema)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let properties = object?["properties"] as? [String: Any]
        #expect(properties?.keys.sorted() == ["response", "title", "tone"])
        let required = object?["required"] as? [String]
        #expect(Set(required ?? []) == ["response", "title", "tone"])
        #expect((object?["additionalProperties"] as? Bool) == false)
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
    }
}
