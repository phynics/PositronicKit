import Foundation
import PKContracts
@testable import PositronicKit
import Testing

@Suite("Agent workspace file tools", .tags(.integration))
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

        #expect((try await write.execute(parameters: ["path": "Notes/MEMORY.md", "content": "hello\n"])).isSuccess)
        #expect((try await append.execute(parameters: ["path": "Notes/MEMORY.md", "content": "world\n"])).isSuccess)
        let edits: AnyCodable = .array([.dictionary([
            "oldText": .string("hello"),
            "newText": .string("updated"),
        ])])
        #expect((try await edit.execute(parameters: ["path": "Notes/MEMORY.md", "edits": edits])).isSuccess)
        let readResult = try await read.execute(parameters: ["path": "Notes/MEMORY.md"])
        #expect(readResult.output.contains("updated\nworld"))
        #expect((try await write.execute(parameters: ["path": "Notes/ambiguous.md", "content": "aaa"])).isSuccess)
        let ambiguous = try await edit.execute(parameters: [
            "path": "Notes/ambiguous.md",
            "edits": .array([.dictionary([
                "oldText": .string("aa"),
                "newText": .string("x"),
            ])]),
        ])
        #expect(!ambiguous.isSuccess)
        #expect((try await delete.execute(parameters: ["path": "Notes/MEMORY.md"])).isSuccess)
    }

    @Test("append creates a missing local file", arguments: ["new.md", "new-directory/new.md"])
    func appendCreatesMissingLocalFile(path: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reference = WorkspaceReference(uri: .agentWorkspace(UUID()), location: .runtime, rootPath: root.path)
        let provider = try LocalAgentWorkspaceProvider(reference: reference)
        let append = AgentWorkspaceFileTool(operation: .appendFile, provider: provider)

        let result = try await append.execute(parameters: ["path": .string(path), "content": "new content"])

        #expect(result.isSuccess)
        #expect(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) == "new content")
    }

    enum LocalReadFailure: CaseIterable, Sendable {
        case oversized
        case invalidUTF8
    }

    @Test("append preserves local files that cannot be read", arguments: LocalReadFailure.allCases)
    func appendPreservesUnreadableLocalFile(failure: LocalReadFailure) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("existing.md")
        let original: Data
        switch failure {
        case .oversized: original = Data(repeating: 0x61, count: 1_024 * 1_024 + 1)
        case .invalidUTF8: original = Data([0xFF, 0xFE, 0x61])
        }
        try original.write(to: file)
        let reference = WorkspaceReference(uri: .agentWorkspace(UUID()), location: .runtime, rootPath: root.path)
        let provider = try LocalAgentWorkspaceProvider(reference: reference)
        let append = AgentWorkspaceFileTool(operation: .appendFile, provider: provider)

        let result = try await append.execute(parameters: ["path": "existing.md", "content": "new content"])

        #expect(!result.isSuccess)
        #expect(result.error?.isEmpty == false)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("append never writes after a provider read failure", arguments: [
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError),
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError),
        NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue)),
        NSError(domain: "CustomWorkspaceError", code: NSFileReadNoSuchFileError),
    ])
    func appendPreservesFileAfterProviderReadFailure(error: NSError) async throws {
        let provider = FailingReadWorkspaceProvider(error: error, content: "existing content")
        let append = AgentWorkspaceFileTool(operation: .appendFile, provider: provider)

        let result = try await append.execute(parameters: ["path": "existing.md", "content": "new content"])

        #expect(!result.isSuccess)
        #expect(result.error == error.localizedDescription)
        #expect(await provider.content == "existing content")
        #expect(await provider.writeCount == 0)
    }

    @Test("append creates files only for recognized missing-file errors", arguments: [
        NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError),
        NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOENT.rawValue)),
    ])
    func appendCreatesMissingProviderFile(error: NSError) async throws {
        let provider = FailingReadWorkspaceProvider(error: error, content: nil)
        let append = AgentWorkspaceFileTool(operation: .appendFile, provider: provider)

        let result = try await append.execute(parameters: ["path": "new.md", "content": "new content"])

        #expect(result.isSuccess)
        #expect(await provider.content == "new content")
        #expect(await provider.writeCount == 1)
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
        #expect(!blocked.isSuccess)
    }
}

private actor FailingReadWorkspaceProvider: WorkspaceFileProvider {
    nonisolated let reference = WorkspaceReference(uri: .agentWorkspace(UUID()), location: .runtime)
    private let error: NSError
    private(set) var content: String?
    private(set) var writeCount = 0

    init(error: NSError, content: String?) {
        self.error = error
        self.content = content
    }

    var isHealthy: Bool { true }

    func readFile(path _: String) async throws -> String { throw error }

    func writeFile(path _: String, content: String) async throws {
        self.content = content
        writeCount += 1
    }

    func listFiles(path _: String) async throws -> [String] { [] }

    func deleteFile(path _: String) async throws {
        content = nil
    }
}
