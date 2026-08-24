import Foundation
@testable import PKContracts
@testable import PositronicKit
import Testing

@Suite("Turn EventHub terminal subscription")
struct TurnEventHubTests {
    @Test("live subscription selection is atomic with the active check")
    func subscribeIfActiveDoesNotAttachAfterFinish() async throws {
        let hub = TurnEventHub()
        let turnID = UUID()

        await hub.begin(turnID: turnID)
        let live = await hub.subscribeIfActive(turnID: turnID)
        #expect(live != nil)

        await hub.finish(turnID: turnID)
        let afterFinish = await hub.subscribeIfActive(turnID: turnID)
        #expect(afterFinish == nil)
    }
}
