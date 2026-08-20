import Foundation
@testable import PKContracts
@testable import PKUtilities
import Testing

/// Edge-case coverage for filesystem tools — the error and validation paths that the
/// happy-path `FilesystemToolsTests` don't exercise.
///
/// Targets: missing parameters, non-existent paths, path-escape rejection, non-directory
/// targets, and the `ChangeDirectoryTool` (which had no tests at all).
@Suite("Filesystem tool edge cases")
struct FilesystemToolEdgeCaseTests {

    private let tempURL: URL

    init() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        try "Hello World".write(to: tempURL.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        let subdir = tempURL.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "Nested".write(to: subdir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - ChangeDirectoryTool

    @Test("ChangeDirectoryTool changes to a valid directory and calls onChange")
    func changeDirectorySucceeds() async throws {
        defer { cleanup() }
        let actor = PathCaptureActor()
        let tool = ChangeDirectoryTool(currentPath: tempURL.path, root: tempURL.path) { path in
            await actor.set(path)
        }
        let subdir = tempURL.appendingPathComponent("subdir").path
        let result = try await tool.execute(parameters: ["path": "subdir"])

        #expect(result.success)
        #expect(result.output.contains(subdir))
        #expect(await actor.path == subdir)
    }

    @Test("ChangeDirectoryTool fails for a non-existent directory")
    func changeDirectoryFailsForMissing() async throws {
        defer { cleanup() }
        let tool = ChangeDirectoryTool(currentPath: tempURL.path, root: tempURL.path) { _ in }
        let result = try await tool.execute(parameters: ["path": "nonexistent"])

        #expect(!result.success)
        #expect(result.error?.contains("not found") == true)
    }

    @Test("ChangeDirectoryTool fails when path is a file, not a directory")
    func changeDirectoryFailsForFile() async throws {
        defer { cleanup() }
        let tool = ChangeDirectoryTool(currentPath: tempURL.path, root: tempURL.path) { _ in }
        let result = try await tool.execute(parameters: ["path": "file1.txt"])

        #expect(!result.success)
        #expect(result.error?.contains("not a directory") == true)
    }

    @Test("ChangeDirectoryTool fails when path parameter is missing")
    func changeDirectoryFailsForMissingParam() async throws {
        defer { cleanup() }
        let tool = ChangeDirectoryTool(currentPath: tempURL.path, root: tempURL.path) { _ in }
        let result = try await tool.execute(parameters: [:])

        #expect(!result.success)
    }

    @Test("ChangeDirectoryTool rejects path escape outside jail")
    func changeDirectoryRejectsEscape() async throws {
        defer { cleanup() }
        let tool = ChangeDirectoryTool(currentPath: tempURL.path, root: tempURL.path) { _ in }
        let result = try await tool.execute(parameters: ["path": "../../etc"])

        #expect(!result.success)
    }

    @Test("ChangeDirectoryTool canExecute returns true")
    func changeDirectoryCanExecute() async throws {
        defer { cleanup() }
        let tool = ChangeDirectoryTool(currentPath: tempURL.path, root: tempURL.path) { _ in }
        #expect(await tool.canExecute() == true)
    }

    // MARK: - ReadFileTool

    @Test("ReadFileTool fails when path parameter is missing")
    func readFileFailsForMissingParam() async throws {
        defer { cleanup() }
        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: [:])

        #expect(!result.success)
    }

    @Test("ReadFileTool fails for a non-existent file")
    func readFileFailsForMissing() async throws {
        defer { cleanup() }
        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "nonexistent.txt"])

        #expect(!result.success)
        #expect(result.error?.contains("not found") == true || result.error?.contains("does not exist") == true)
    }

    @Test("ReadFileTool rejects path escape outside jail")
    func readFileRejectsEscape() async throws {
        defer { cleanup() }
        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "../../../etc/passwd"])

        #expect(!result.success)
    }

    // MARK: - ListDirectoryTool

    @Test("ListDirectoryTool defaults to current directory when path is missing")
    func listDirectoryDefaultsToCurrent() async throws {
        defer { cleanup() }
        let tool = ListDirectoryTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: [:])

        #expect(result.success)
        #expect(result.output.contains("file1.txt"))
    }

    @Test("ListDirectoryTool fails for a non-existent directory")
    func listDirectoryFailsForMissing() async throws {
        defer { cleanup() }
        let tool = ListDirectoryTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "nonexistent"])

        #expect(!result.success)
    }

    @Test("ListDirectoryTool rejects path escape outside jail")
    func listDirectoryRejectsEscape() async throws {
        defer { cleanup() }
        let tool = ListDirectoryTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "../../etc"])

        #expect(!result.success)
    }

    // MARK: - FindFileTool

    @Test("FindFileTool defaults to current directory when path is missing")
    func findFileDefaultsToCurrent() async throws {
        defer { cleanup() }
        let tool = FindFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["pattern": "file"])

        #expect(result.success)
        #expect(result.output.contains("file1.txt"))
    }

    @Test("FindFileTool fails when pattern parameter is missing")
    func findFileFailsForMissingPattern() async throws {
        defer { cleanup() }
        let tool = FindFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "."])

        #expect(!result.success)
    }

    @Test("FindFileTool returns no results for a non-matching pattern")
    func findFileNoMatch() async throws {
        defer { cleanup() }
        let tool = FindFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": ".", "pattern": "zzznomatch"])

        #expect(result.success)
        #expect(result.output.contains("No files") || result.output.contains("0"))
    }

    @Test("FindFileTool rejects path escape outside jail")
    func findFileRejectsEscape() async throws {
        defer { cleanup() }
        let tool = FindFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "../../etc", "pattern": "passwd"])

        #expect(!result.success)
    }
}

// MARK: - Test helpers

private actor PathCaptureActor {
    private(set) var path: String?

    func set(_ path: String) {
        self.path = path
    }
}
