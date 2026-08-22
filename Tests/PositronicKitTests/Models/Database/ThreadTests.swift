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
}
