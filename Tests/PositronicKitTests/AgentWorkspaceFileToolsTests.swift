import Foundation
import PKContracts
@testable import PositronicKit
import Testing

@Suite("Agent workspace file tools")
struct AgentWorkspaceFileToolsTests {
    @Test("supports generic file lifecycle and exact edits")
    func fileLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reference = WorkspaceReference(uri: .agentWorkspace(UUID()), location: .runtime, rootPath: root.path)
        let provider = try LocalAgentWorkspaceProvider(reference: reference)
        let write = AgentWorkspaceFileTool(operation: .writeFile, provider: provider)
        let append = AgentWorkspaceFileTool(operation: .appendFile, provider: provider)
        let edit = AgentWorkspaceFileTool(operation: .editFile, provider: provider)
        let read = AgentWorkspaceFileTool(operation: .readFile, provider: provider)
        let delete = AgentWorkspaceFileTool(operation: .deleteFile, provider: provider)

        #expect((try await write.execute(parameters: ["path": "Notes/MEMORY.md", "content": "hello\n"])).success)
        #expect((try await append.execute(parameters: ["path": "Notes/MEMORY.md", "content": "world\n"])).success)
        let edits: AnyCodable = .array([.dictionary([
            "oldText": .string("hello"),
            "newText": .string("updated"),
        ])])
        #expect((try await edit.execute(parameters: ["path": "Notes/MEMORY.md", "edits": edits])).success)
        let readResult = try await read.execute(parameters: ["path": "Notes/MEMORY.md"])
        #expect(readResult.output.contains("updated\nworld"))
        #expect((try await write.execute(parameters: ["path": "Notes/ambiguous.md", "content": "aaa"])).success)
        let ambiguous = try await edit.execute(parameters: [
            "path": "Notes/ambiguous.md",
            "edits": .array([.dictionary([
                "oldText": .string("aa"),
                "newText": .string("x"),
            ])]),
        ])
        #expect(!ambiguous.success)
        #expect((try await delete.execute(parameters: ["path": "Notes/MEMORY.md"])).success)
    }

    @Test("jails paths and requests approval only for SOUL mutations")
    func pathAndApprovalPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reference = WorkspaceReference(uri: .agentWorkspace(UUID()), location: .runtime, rootPath: root.path)
        let provider = try LocalAgentWorkspaceProvider(reference: reference)
        let write = AgentWorkspaceFileTool(operation: .writeFile, provider: provider)

        try "identity".write(to: root.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Notes/soul-alias.md").path,
            withDestinationPath: root.appendingPathComponent("SOUL.md").path
        )
        #expect(write.requiresPermission(for: ["path": "SOUL.md", "content": "new identity"]))
        #expect(write.requiresPermission(for: ["path": "soul.md", "content": "new identity"]))
        #expect(write.requiresPermission(for: ["path": "Notes/soul-alias.md", "content": "new identity"]))
        #expect(!write.requiresPermission(for: ["path": "Notes/MEMORY.md", "content": "new memory"]))
        let blocked = try await write.execute(parameters: [
            "path": "../outside.md",
            "content": "must not escape",
        ])
        #expect(!blocked.success)
    }
}
