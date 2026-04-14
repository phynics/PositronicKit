import Testing
@testable import PositronicKit
@testable import PKShared
import Foundation

@Suite final class WorkspaceReferenceTests {
    private func assertCodable<T: Codable>(_ value: T) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(value)
        _ = try decoder.decode(T.self, from: data)
    }

    @Test

    func testWorkspaceReferenceCodable() throws {
        let ref = WorkspaceReference(
            id: UUID(),
            uri: WorkspaceURI(host: "local", path: "/tmp/test"),
            hostType: .runtime
        )
        try assertCodable(ref)
    }

    @Test

    func testWorkspaceReferenceWithClientHost() throws {
        let ownerId = UUID()
        let ref = WorkspaceReference(
            id: UUID(),
            uri: WorkspaceURI(host: "macbook", path: "/Users/dev"),
            hostType: .external,
            ownerId: ownerId,
            status: .missing
        )
        try assertCodable(ref)
        #expect(ref.ownerId == ownerId)
        #expect(ref.status == .missing)
    }
}
