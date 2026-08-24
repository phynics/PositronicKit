import Foundation
@testable import PositronicKit
@testable import PKContracts
import PKUtilities
import Testing

@Suite final class ThreadTests {
    private func assertCodable<T: Codable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(value)
        _ = try decoder.decode(T.self, from: data)
    }

    @Test
    func threadCodable() throws {
        let thread = Thread(title: "Test Session")
        try assertCodable(thread)
    }

    @Test
    func threadCodableOmitsWorkspaceProjection() throws {
        let thread = Thread(title: "Project Alpha")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(thread)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["attachedWorkspaceIds"] == nil)
    }

    @Test
    func legacyWorkspaceProjectionIsIgnoredDuringDecode() throws {
        let threadID = UUID()
        let legacyWorkspaceID = UUID()
        let legacyObject: [String: Any] = [
            "id": threadID.uuidString,
            "title": "Legacy thread",
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

        let decoded = try decoder.decode(Thread.self, from: data)

        #expect(decoded.id == threadID)
        #expect(decoded.title == "Legacy thread")
        #expect(decoded.workingDirectory == nil)
    }
}
