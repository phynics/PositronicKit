import Foundation
@testable import PKContracts
import Testing

struct SidecarEventsTests {
    @Test func sidecarDeltaEventRoundTrips() throws {
        let event = ChatEvent.sidecar(SidecarDelta(name: "title", partialText: "Refactoring the", isFinal: false))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ChatEvent.self, from: data)
        #expect(decoded.sidecarDelta?.name == "title")
        #expect(decoded.sidecarDelta?.partialText == "Refactoring the")
        #expect(decoded.sidecarDelta?.isFinal == false)
    }

    @Test func sidecarsCompletedCarriesValuesAndErrors() throws {
        let sendId = UUID()
        let results = [
            SidecarResult(name: "title", outcome: .value(AnyCodable("A Title"))),
            SidecarResult(name: "tone", outcome: .declined),
            SidecarResult(name: "memory", outcome: .failed(reason: "field never completed")),
        ]
        let completion = SidecarCompletion(
            identity: TurnIdentity(sendID: sendId, roundTrip: 2),
            results: results
        )
        let event = ChatEvent.sidecarsCompleted(completion)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ChatEvent.self, from: data)
        #expect(decoded.sidecarResults?.count == 3)
        #expect(decoded.sidecarResults?[1].outcome == .declined)
        #expect(decoded.sidecarCompletion?.identity == completion.identity)
        #expect(decoded.sidecarCompletion?.results == results)
    }

    @Test func turnIdentityAndCommitPolicyRoundTripThroughCodable() throws {
        let identity = TurnIdentity(sendID: UUID(), roundTrip: 7)
        let identityData = try JSONEncoder().encode(identity)
        #expect(try JSONDecoder().decode(TurnIdentity.self, from: identityData) == identity)

    }
}
