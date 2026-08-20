import Testing
@testable import PKContracts
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
            location: .runtime
        )
        try assertCodable(ref)
    }

    @Test

    func testWorkspaceReferenceWithAttachedOrigin() throws {
        let originId = UUID()
        let ref = WorkspaceReference(
            id: UUID(),
            uri: WorkspaceURI(host: "macbook", path: "/Users/dev"),
            location: .attached,
            originID: originId,
            status: .missing
        )
        try assertCodable(ref)
        #expect(ref.originID == originId)
        #expect(ref.status == .missing)
    }
}
