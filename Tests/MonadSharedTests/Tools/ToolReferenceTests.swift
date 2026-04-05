import Testing
@testable import MonadShared
import Foundation

@Suite final class ToolReferenceTests {
    private func assertCodable<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(value == decoded)
    }

    @Test

    func testToolReferenceCodable() throws {
        let ref = ToolReference.known("search-api")
        try assertCodable(ref)
        #expect(ref.displayName == "search-api")
        #expect(ref.toolId == "search-api")
    }

    @Test

    func testToolReferenceWithWorkspace() throws {
        let def = WorkspaceToolDefinition(
            id: "list-files",
            name: "List Files",
            description: "Lists workspace files"
        )
        let ref = ToolReference.custom(def)
        try assertCodable(ref)
        #expect(ref.displayName == "List Files")
        #expect(ref.toolId == "list-files")
    }
}
