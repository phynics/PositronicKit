import Foundation
@testable import PKContracts
import Testing

struct SidecarEventsTests {
    @Test func sidecarDeltaEventRoundTrips() throws {
        let event = TurnEvent.sidecar(SidecarDelta(name: "title", partialText: "Refactoring the", isFinal: false))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(TurnEvent.self, from: data)
        #expect(decoded.sidecarDelta?.name == "title")
        #expect(decoded.sidecarDelta?.partialText == "Refactoring the")
        #expect(decoded.sidecarDelta?.isFinal == false)
    }

    @Test func sidecarsCompletedCarriesValuesAndErrors() throws {
        let requestId = UUID()
        let results = [
            SidecarResult(name: "title", outcome: .value(AnyCodable("A Title"))),
            SidecarResult(name: "tone", outcome: .declined),
            SidecarResult(name: "memory", outcome: .failed(reason: "field never completed")),
        ]
        let completion = SidecarCompletion(
            identity: TurnIdentity(turnID: UUID(), requestID: requestId, modelRoundIndex: 2),
            results: results
        )
        let event = TurnEvent.sidecarsCompleted(completion)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(TurnEvent.self, from: data)
        #expect(decoded.sidecarResults?.count == 3)
        #expect(decoded.sidecarResults?[1].outcome == .declined)
        #expect(decoded.sidecarCompletion?.identity == completion.identity)
        #expect(decoded.sidecarCompletion?.results == results)
    }

    @Test func turnIdentityAndCommitPolicyRoundTripThroughCodable() throws {
        let identity = TurnIdentity(turnID: UUID(), requestID: UUID(), modelRoundIndex: 7)
        let identityData = try JSONEncoder().encode(identity)
        #expect(try JSONDecoder().decode(TurnIdentity.self, from: identityData) == identity)

    }
}
