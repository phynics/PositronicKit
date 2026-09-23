import Foundation
@testable import PKContracts
import Testing

/// Pins the exact JSON wire format of every `TurnEvent` payload shape, so a change to how the
/// event enums are coded cannot silently change what hosts persist or transmit (#229).
@Suite("TurnEvent wire format")
struct TurnEventWireFormatTests {
    private static func assertWireFormat<Value: Codable>(
        _ value: Value,
        _ json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try String(decoding: encoder.encode(value), as: UTF8.self)
        #expect(encoded == json, sourceLocation: sourceLocation)
        let decoded = try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        let reencoded = try String(decoding: encoder.encode(decoded), as: UTF8.self)
        #expect(reencoded == json, sourceLocation: sourceLocation)
    }

    @Test("delta payloads keep their keys")
    func deltaWireFormat() throws {
        try Self.assertWireFormat(TurnEvent.DeltaEvent.reasoning(text: "r"), #"{"reasoning":{"text":"r"}}"#)
        try Self.assertWireFormat(TurnEvent.DeltaEvent.generation(text: "g"), #"{"generation":{"text":"g"}}"#)
        try Self.assertWireFormat(
            TurnEvent.DeltaEvent.toolExecution(toolCallID: "c", status: .executionError("e")),
            #"{"toolExecution":{"status":{"executionError":{"_0":"e"}},"toolCallId":"c"}}"#
        )
    }

    @Test("error payloads keep their keys and omit a missing identity")
    func errorWireFormat() throws {
        try Self.assertWireFormat(
            TurnEvent.ErrorEvent.toolCallError(toolCallID: "c", name: "n", error: "e"),
            #"{"toolCallError":{"error":"e","name":"n","toolCallId":"c"}}"#
        )
        try Self.assertWireFormat(
            TurnEvent.ErrorEvent.error(message: "m", identity: nil),
            #"{"error":{"message":"m"}}"#
        )
        try Self.assertWireFormat(
            TurnEvent.ErrorEvent.durabilityFailure(message: "m", identity: nil),
            #"{"durabilityFailure":{"message":"m"}}"#
        )
        try Self.assertWireFormat(TurnEvent.ErrorEvent.generationCancelled, #"{"generationCancelled":{}}"#)
    }

    @Test("completion payloads keep their keys and empty objects")
    func completionWireFormat() throws {
        try Self.assertWireFormat(TurnEvent.CompletionEvent.completedEmpty(finishReason: nil), #"{"completedEmpty":{}}"#)
        try Self.assertWireFormat(
            TurnEvent.CompletionEvent.completedEmpty(finishReason: "stop"),
            #"{"completedEmpty":{"finishReason":"stop"}}"#
        )
        try Self.assertWireFormat(
            TurnEvent.CompletionEvent.toolExecution(toolCallID: "c", status: .executionError("e")),
            #"{"toolExecution":{"status":{"executionError":{"_0":"e"}},"toolCallId":"c"}}"#
        )
        try Self.assertWireFormat(TurnEvent.CompletionEvent.maxModelRoundsReached, #"{"maxModelRoundsReached":{}}"#)
        try Self.assertWireFormat(TurnEvent.CompletionEvent.deferredForExternalTool, #"{"deferredForExternalTool":{}}"#)
    }
}
