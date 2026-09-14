import Foundation
@testable import PositronicKit
@testable import PKContracts
import PKUtilities
import Testing

@Suite(.tags(.unit)) final class TimelineTests {
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
        let timeline = TimelineRecord(title: "Test Session")
        try assertCodable(timeline)
    }

    @Test
    func timelineCodableOmitsWorkspaceProjection() throws {
        let timeline = TimelineRecord(title: "Project Alpha")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(timeline)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["attachedWorkspaceIds"] == nil)
    }

    @Test
    func legacyWorkspaceProjectionIsIgnoredDuringDecode() throws {
        let timelineID = UUID()
        let legacyWorkspaceID = UUID()
        let legacyObject: [String: Any] = [
            "id": timelineID.uuidString,
            "title": "Legacy timeline",
            "createdAt": "2026-08-24T00:00:00Z",
            "updatedAt": "2026-08-24T00:00:00Z",
            "isArchived": false,
            // 4.0.0 persisted this projection as a JSON string.
            "attachedWorkspaceIds": "[\"\(legacyWorkspaceID.uuidString)\"]",
            "isPrivate": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(TimelineRecord.self, from: data)

        #expect(decoded.id == timelineID)
        #expect(decoded.title == "Legacy timeline")
        #expect(decoded.workingDirectory == nil)
    }
}
