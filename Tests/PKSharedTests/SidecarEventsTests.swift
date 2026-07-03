import Foundation
@testable import PKShared
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
        let results = [
            SidecarResult(name: "title", outcome: .value(AnyCodable("A Title"))),
            SidecarResult(name: "tone", outcome: .declined),
            SidecarResult(name: "memory", outcome: .failed(reason: "field never completed")),
        ]
        let event = ChatEvent.sidecarsCompleted(results)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ChatEvent.self, from: data)
        #expect(decoded.sidecarResults?.count == 3)
        #expect(decoded.sidecarResults?[1].outcome == .declined)
    }
}
