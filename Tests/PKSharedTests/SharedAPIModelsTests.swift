import Foundation
@testable import PKShared
import Testing

@Suite final class SharedAPIModelsTests {
    @Test
    func chatEventCodable() throws {
        let event = ChatEvent.generation("Pong")
        let data = try JSONEncoder().encode(event)
        #expect(data.count > 0)
    }

    @Test
    func requestOriginIdentityCodable() throws {
        let origin = RequestOriginIdentity(hostname: "macbook", displayName: "Atakan's Mac", platform: "macos")
        let data = try JSONEncoder().encode(origin)
        #expect(data.count > 0)
        #expect(origin.shellWorkspaceURI.host == "macbook")
    }
}
