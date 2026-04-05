import Foundation
@testable import MonadCore
@testable import MonadShared
import Testing

@Suite final class TimelineTests {
    private func assertCodable<T: Codable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(value)
        _ = try decoder.decode(T.self, from: data)
    }

    @Test
    func timelineCodable() throws {
        let timeline = Timeline(title: "Test Session")
        try assertCodable(timeline)
    }

    @Test
    func timelineWithWorkspacesCodable() throws {
        let attachedId = UUID()
        let timeline = Timeline(
            title: "Project Alpha",
            attachedWorkspaceIds: [attachedId]
        )

        try assertCodable(timeline)
        #expect(timeline.attachedWorkspaceIds.first == attachedId)
    }
}
