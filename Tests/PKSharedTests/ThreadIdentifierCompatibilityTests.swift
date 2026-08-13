import Foundation
import PositronicKit
import Testing

@Suite("Thread identifiers")
struct ThreadIdentifierCompatibilityTests {
    private typealias Thread = PositronicKit.Thread

    @Test("the timeline typealias preserves value compatibility")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func legacyTimelineTypealias() {
        let thread = Thread(title: "Legacy")
        let timeline: Timeline = thread

        #expect(timeline.id == thread.id)
        #expect(timeline.title == thread.title)
    }

    @Test("canonical Codable keeps historical persistence keys")
    func canonicalCodableKeepsHistoricalKeys() throws {
        let thread = Thread(
            attachedWorkspaceIDs: [UUID()],
            attachedAgentInstanceID: UUID()
        )
        let data = try JSONEncoder().encode(thread)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["attachedWorkspaceIds"] != nil)
        #expect(object["attachedAgentInstanceId"] != nil)
        #expect(object["attachedWorkspaceIDs"] == nil)
    }
}
