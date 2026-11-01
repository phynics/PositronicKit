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

    @Test("search reports file-budget truncation at the 200-file boundary")
    func searchReportsFileBudgetTruncation() async throws {
        let belowLimitProvider = SearchWorkspaceProvider(files: Dictionary(uniqueKeysWithValues: (1...199).map {
            (String(format: "file-%03d.txt", $0), "other")
        }))
        let belowLimit = try await AgentWorkspaceFileTool(operation: .searchFiles, provider: belowLimitProvider)
            .execute(parameters: ["pattern": "needle"])
        #expect(belowLimit.isSuccess)
        #expect(belowLimit.output == "No matches found.")
        #expect(await belowLimitProvider.readCount == 199)

        let overLimitProvider = SearchWorkspaceProvider(files: Dictionary(uniqueKeysWithValues: (1...201).map { index in
            (String(format: "file-%03d.txt", index), index == 201 ? "needle" : "other")
        }))
        let tool = AgentWorkspaceFileTool(operation: .searchFiles, provider: overLimitProvider)

        let atLimitProvider = SearchWorkspaceProvider(files: Dictionary(uniqueKeysWithValues: (1...200).map {
            (String(format: "file-%03d.txt", $0), "other")
        }))
        let atLimit = try await AgentWorkspaceFileTool(operation: .searchFiles, provider: atLimitProvider)
            .execute(parameters: ["pattern": "needle"])
        #expect(atLimit.isSuccess)
        #expect(!atLimit.output.contains("incomplete"))
        #expect(await atLimitProvider.readCount == 200)

        let overLimit = try await tool.execute(parameters: ["pattern": "needle"])
        #expect(overLimit.isSuccess)
        #expect(overLimit.output.contains("No matches found in readable files."))
        #expect(!overLimit.output.contains("file-201.txt"))
        #expect(overLimit.output.contains("incomplete"))
        #expect(overLimit.output.contains("skipped 1 file"))
        #expect(await overLimitProvider.readCount == 200)
    }

    @Test("search reports unreadable files as incomplete")
    func searchReportsUnreadableFiles() async throws {
        let provider = SearchWorkspaceProvider(
            files: ["a-unreadable.txt": "", "b-readable.txt": "needle"],
            unreadable: ["a-unreadable.txt"]
        )
        let tool = AgentWorkspaceFileTool(operation: .searchFiles, provider: provider)

        let result = try await tool.execute(parameters: ["pattern": "needle"])

        #expect(result.isSuccess)
        #expect(result.output.contains("b-readable.txt:1: needle"))
        #expect(result.output.contains("incomplete"))
        #expect(result.output.contains("1 file"))
    }

    @Test("search returns an explicit no-match result when every file was searched")
    func searchReportsCompleteNoMatches() async throws {
        let provider = SearchWorkspaceProvider(files: ["a.txt": "other"])
        let tool = AgentWorkspaceFileTool(operation: .searchFiles, provider: provider)

        let result = try await tool.execute(parameters: ["pattern": "needle"])

        #expect(result.isSuccess)
        #expect(result.output.contains("No matches found"))
        #expect(!result.output.contains("incomplete"))
    }

    @Test("search reports files truncated at the content byte limit")
    func searchReportsContentTruncation() async throws {
        let byteLimit = 256 * 1_024
        let afterLimit = SearchWorkspaceProvider(files: [
            "large.txt": String(repeating: "x", count: byteLimit) + "needle",
        ])
        let afterLimitResult = try await AgentWorkspaceFileTool(operation: .searchFiles, provider: afterLimit)
            .execute(parameters: ["pattern": "needle"])
        #expect(afterLimitResult.isSuccess)
        #expect(afterLimitResult.output.contains("No matches found in readable files."))
        #expect(afterLimitResult.output.contains("stopped reading 1 file at the 262144-byte content limit"))

        let exactBoundary = SearchWorkspaceProvider(files: [
            "exact.txt": String(repeating: "x", count: byteLimit - "\nneedle".utf8.count) + "\nneedle",
        ])
        let exactBoundaryResult = try await AgentWorkspaceFileTool(operation: .searchFiles, provider: exactBoundary)
            .execute(parameters: ["pattern": "needle"])
        #expect(exactBoundaryResult.output == "exact.txt:2: needle")
        #expect(!exactBoundaryResult.output.contains("Search incomplete"))

        let multibyte = SearchWorkspaceProvider(files: [
            "multibyte.txt": String(repeating: "x", count: byteLimit - 1) + "éneedle",
        ])
        let multibyteResult = try await AgentWorkspaceFileTool(operation: .searchFiles, provider: multibyte)
            .execute(parameters: ["pattern": "needle|output truncated"])
        #expect(multibyteResult.isSuccess)
        #expect(!multibyteResult.output.contains("multibyte.txt:"))
        #expect(multibyteResult.output.contains("stopped reading 1 file at the 262144-byte content limit"))
        #expect(!multibyteResult.output.contains("output truncated"))
    }

    @Test("search reports when the match output reaches its limit")
    func searchReportsMatchLimit() async throws {
        let provider = SearchWorkspaceProvider(files: ["matches.txt": String(repeating: "needle\n", count: 101)])
        let tool = AgentWorkspaceFileTool(operation: .searchFiles, provider: provider)

        let result = try await tool.execute(parameters: ["pattern": "needle"])

        #expect(result.isSuccess)
        #expect(result.output.components(separatedBy: "matches.txt:").count - 1 == 100)
        #expect(result.output.contains("Search incomplete: stopped after the first 100 matches."))
    }

    @Test("search preserves task cancellation")
    func searchPreservesCancellation() async throws {
        let provider = SearchWorkspaceProvider(files: ["a.txt": "needle"])
        let tool = AgentWorkspaceFileTool(operation: .searchFiles, provider: provider)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tool.execute(parameters: ["pattern": "needle"])
        }
        let result = try await task.value

        #expect(!result.isSuccess)
        #expect(result.error?.isEmpty == false)
        #expect(await provider.readCount == 0)
    }

    @Test("jails paths and requests approval for configured protected paths")
    func pathAndApprovalPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reference = WorkspaceReference(uri: .agentWorkspace(UUID()), location: .runtime, rootPath: root.path)
        let provider = try LocalAgentWorkspaceProvider(reference: reference)
        let write = AgentWorkspaceFileTool(
            operation: .writeFile,
            provider: provider,
            protectedPaths: ["SOUL.md"]
        )

        try "identity".write(to: root.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Notes/soul-alias.md").path,
            withDestinationPath: root.appendingPathComponent("SOUL.md").path
        )
        #expect(write.requiresPermission(for: ["path": "SOUL.md", "content": "new identity"]))
        #expect(write.requiresPermission(for: ["path": "soul.md", "content": "new identity"]))
        #expect(write.requiresPermission(for: ["path": "Notes/soul-alias.md", "content": "new identity"]))
        #expect(write.requiresPermission(for: ["path": "Notes/MEMORY.md", "content": "new memory"]) == false)
        let protectAll = AgentWorkspaceFileTool(
            operation: .writeFile,
            provider: provider,
            protectedPaths: ["**"]
        )
        #expect(protectAll.requiresPermission(for: ["path": "Notes/MEMORY.md", "content": "new memory"]))
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

private actor SearchWorkspaceProvider: WorkspaceFileProvider {
    nonisolated let reference = WorkspaceReference(uri: .agentWorkspace(UUID()), location: .runtime)
    private let files: [String: String]
    private let unreadable: Set<String>
    private(set) var readCount = 0

    init(files: [String: String], unreadable: Set<String> = []) {
        self.files = files
        self.unreadable = unreadable
    }

    var isHealthy: Bool { true }

    func readFile(path: String) async throws -> String {
        readCount += 1
        if unreadable.contains(path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        return files[path] ?? ""
    }

    func listFiles(path _: String) async throws -> [String] { Array(files.keys).sorted() }
    func writeFile(path _: String, content _: String) async throws {}
    func deleteFile(path _: String) async throws {}
}
