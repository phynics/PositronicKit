import Foundation
@testable import PKContracts
import PositronicKit
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
        try Self.assertWireFormat(
            TurnEvent.DeltaEvent.toolExecution(toolCallID: "c", status: .success(.success("ok"))),
            #"{"toolExecution":{"status":{"success":{"_0":{"isSuccess":true,"output":"ok"}}},"toolCallId":"c"}}"#
        )
        let reference = ToolReference.known("tool-1")
        try Self.assertWireFormat(
            TurnEvent.DeltaEvent.toolExecution(
                toolCallID: "c",
                status: .failed(reference: reference, error: "e")
            ),
            #"{"toolExecution":{"status":{"failed":{"error":"e","reference":{"id":"tool-1","type":"known"}}},"toolCallId":"c"}}"#
        )
        let workspaceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        try Self.assertWireFormat(
            TurnEvent.DeltaEvent.toolExecution(
                toolCallID: "c",
                status: .workspaceFailed(
                    reference: reference,
                    error: "e",
                    workspaceID: workspaceID,
                    routing: .explicit
                )
            ),
            #"{"toolExecution":{"status":{"workspaceFailed":{"error":"e","reference":{"id":"tool-1","type":"known"},"routing":"explicit","workspaceID":"00000000-0000-0000-0000-000000000001"}},"toolCallId":"c"}}"#
        )
        try Self.assertWireFormat(
            TurnEvent.DeltaEvent.toolExecution(
                toolCallID: "c",
                status: .workspaceSucceeded(
                    result: .success("ok"),
                    workspaceID: workspaceID,
                    routing: .explicit
                )
            ),
            #"{"toolExecution":{"status":{"success":{"_0":{"isSuccess":true,"output":"ok","workspaceID":"00000000-0000-0000-0000-000000000001","workspaceRouting":"explicit"}}},"toolCallId":"c"}}"#
        )
        let definition = ToolDefinition(
            id: "tool-1",
            name: "Read file",
            description: "Reads one file",
            parametersSchema: ["type": .string("object")],
            usageExample: "read_file(path: \"README.md\")",
            requiresPermission: true,
            contextInjection: "Read the requested file."
        )
        try Self.assertWireFormat(
            TurnEvent.DeltaEvent.toolExecution(
                toolCallID: "c",
                status: .attempting(name: "read_file", reference: .custom(definition))
            ),
            #"{"toolExecution":{"status":{"attempting":{"name":"read_file","reference":{"definition":{"contextInjection":"Read the requested file.","description":"Reads one file","id":"tool-1","name":"Read file","parametersSchema":{"type":"object"},"requiresPermission":true,"usageExample":"read_file(path: \"README.md\")"},"type":"custom"}}},"toolCallId":"c"}}"#
        )
        try Self.assertWireFormat(
            TurnEvent.DeltaEvent.toolExecution(
                toolCallID: "c",
                status: .persistenceFailed(reference: reference, error: "e")
            ),
            #"{"toolExecution":{"status":{"persistenceFailed":{"error":"e","reference":{"id":"tool-1","type":"known"}}},"toolCallId":"c"}}"#
        )
        try Self.assertWireFormat(
            TurnEvent.DeltaEvent.toolExecution(
                toolCallID: "c",
                status: .workspacePersistenceFailed(
                    reference: reference,
                    error: "e",
                    workspaceID: workspaceID,
                    routing: .implicit
                )
            ),
            #"{"toolExecution":{"status":{"workspacePersistenceFailed":{"error":"e","reference":{"id":"tool-1","type":"known"},"routing":"implicit","workspaceID":"00000000-0000-0000-0000-000000000001"}},"toolCallId":"c"}}"#
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

    @Test("prompt cache report payload round-trips through synthesized Codable")
    func promptCacheReportWireFormat() throws {
        let report = PromptCacheReport(
            turnID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            modelRoundIndex: 1,
            policy: .automatic(retention: .short),
            breakpoints: [
                PromptCacheBreakpoint(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 10),
            ],
            expectedReusableTokens: 42,
            reportedCachedTokens: 30,
            reportedCacheWriteTokens: 12,
            resets: [.firstRound]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(TurnEvent.promptCacheReport(report))
        let decoded = try JSONDecoder().decode(TurnEvent.self, from: encoded)
        #expect(try encoder.encode(decoded) == encoded)
    }
}
