import Testing
@testable import PKContracts

@Suite struct FinishReasonTests {
    @Test("Recognized wire values map onto the corresponding case")
    func recognizedWireValuesMapToCases() {
        #expect(FinishReason(wireValue: "stop") == .stop)
        #expect(FinishReason(wireValue: "tool_calls") == .toolCalls)
        #expect(FinishReason(wireValue: "length") == .length)
        #expect(FinishReason(wireValue: "content_filter") == .contentFilter)
    }

    @Test("Unrecognized wire values are preserved via .other(_:) rather than dropped")
    func unrecognizedWireValuesArePreservedAsOther() {
        #expect(FinishReason(wireValue: "function_call") == .other("function_call"))
        #expect(FinishReason(wireValue: "error") == .other("error"))
        #expect(FinishReason(wireValue: "something_new") == .other("something_new"))
    }

    @Test("wireValue round-trips back to the original string for every case")
    func wireValueRoundTripsForKnownCases() {
        #expect(FinishReason.stop.wireValue == "stop")
        #expect(FinishReason.toolCalls.wireValue == "tool_calls")
        #expect(FinishReason.length.wireValue == "length")
        #expect(FinishReason.contentFilter.wireValue == "content_filter")
        #expect(FinishReason.other("weird_value").wireValue == "weird_value")
    }

    @Test("Round-tripping an arbitrary wire string through init and wireValue is identity-preserving")
    func modelRoundIndexIsIdentityPreserving() {
        for raw in ["stop", "tool_calls", "length", "content_filter", "function_call", "custom_reason"] {
            #expect(FinishReason(wireValue: raw).wireValue == raw)
        }
    }
}
