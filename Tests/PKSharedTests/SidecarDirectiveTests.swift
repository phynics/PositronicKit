import Foundation
import JSONSchemaBuilder
@testable import PKShared
import Testing

struct SidecarDirectiveTests {
    private func makeDirective(name: String = "title") -> SidecarDirective {
        SidecarDirective(
            name: name,
            instruction: "Generate a short title. Return null to decline.",
            schema: JSONString().definition(),
            streaming: .buffered
        )
    }

    @Test func directiveRoundTripsThroughCodable() throws {
        let directive = makeDirective()
        let data = try JSONEncoder().encode(directive)
        let decoded = try JSONDecoder().decode(SidecarDirective.self, from: data)
        #expect(decoded == directive)
    }

    @Test func reservedResponseNameIsInvalid() {
        #expect(SidecarDirective.reservedFieldName == "response")
        #expect(!makeDirective(name: "response").hasValidName)
        #expect(makeDirective(name: "title").hasValidName)
    }

    @Test func emptyNameIsInvalid() {
        #expect(!makeDirective(name: "").hasValidName)
    }
}
