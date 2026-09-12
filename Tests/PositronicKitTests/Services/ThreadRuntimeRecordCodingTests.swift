import Foundation
import PKContracts
import PositronicKit
import Testing

@Suite("Thread runtime record coding")
struct ThreadRuntimeRecordCodingTests {
    @Test("Renamed durable fields preserve their legacy JSON keys")
    func renamedDurableFieldsPreserveLegacyJSONKeys() throws {
        let turn = TurnRecord(
            identity: TurnIdentity(turnID: UUID(), requestID: UUID(), modelRoundIndex: 1),
            threadID: UUID(),
            callerIntent: TurnCallerIntent(requestID: UUID(), fingerprint: "fingerprint"),
            requiresRecovery: true
        )
        let toolResult = RuntimeToolResult(
            turnID: turn.identity.turnID,
            threadID: turn.threadID,
            toolCallID: "call-1",
            output: "done",
            isSuccessful: false
        )

        let turnObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(turn)) as? [String: Any]
        )
        let toolObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(toolResult)) as? [String: Any]
        )

        #expect(turnObject["recoveryRequired"] as? Bool == true)
        #expect(turnObject["requiresRecovery"] == nil)
        #expect(toolObject["succeeded"] as? Bool == false)
        #expect(toolObject["isSuccessful"] == nil)
    }
}
