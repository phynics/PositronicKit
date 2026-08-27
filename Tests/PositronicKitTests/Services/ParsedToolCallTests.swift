import Foundation
@testable import PositronicKit
import Testing

// MARK: - ParsedToolCall decode contract tests

struct ParsedToolCallTests {
    @Test("Valid JSON object decodes to non-nil arguments")
    func validJSONDecodes() {
        let call = ParsedToolCall(callId: "1", name: "test", argumentsJSON: "{\"key\": \"value\"}")
        #expect(call.arguments != nil)
        #expect(call.arguments?["key"]?.value as? String == "value")
    }

    @Test("Invalid JSON produces nil arguments, not empty dictionary")
    func invalidJSONProducesNil() {
        let call = ParsedToolCall(callId: "2", name: "test", argumentsJSON: "not json at all")
        #expect(call.arguments == nil)
    }

    @Test("Non-object JSON (array) produces nil arguments")
    func arrayJSONProducesNil() {
        let call = ParsedToolCall(callId: "3", name: "test", argumentsJSON: "[1,2,3]")
        #expect(call.arguments == nil)
    }

    @Test("Empty string produces nil arguments")
    func emptyStringProducesNil() {
        let call = ParsedToolCall(callId: "4", name: "test", argumentsJSON: "")
        #expect(call.arguments == nil)
    }

    @Test("Empty JSON object decodes to empty dictionary")
    func emptyObjectDecodes() {
        let call = ParsedToolCall(callId: "5", name: "test", argumentsJSON: "{}")
        #expect(call.arguments != nil)
        #expect(call.arguments?.isEmpty == true)
    }
}
