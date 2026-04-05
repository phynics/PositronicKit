import Testing
@testable import MonadCore
@testable import MonadShared
import Foundation

@Suite final class WorkspaceToolDefinitionTests {
    private func assertCodable<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(value == decoded)
    }

    @Test

    func testWorkspaceToolDefinitionCodable() throws {
        let def = WorkspaceToolDefinition(
            id: "tool-id-1",
            name: "test_tool",
            description: "A test tool",
            parametersSchema: ["input": AnyCodable("string")],
            usageExample: "test_tool --input abc",
            requiresPermission: true
        )
        try assertCodable(def)
        #expect(def.id == "tool-id-1")
        #expect(def.requiresPermission)
    }
}
