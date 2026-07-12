import Foundation
@testable import PKShared
import Testing

struct FilesystemToolsTests {
    let tempURL: URL

    init() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)

        // Structure:
        // /root
        //   - file1.txt ("Hello World")
        //   - file2.md ("Markdown content")
        //   - /subdir
        //     - nested.txt ("Nested Hello")

        try "Hello World".write(to: tempURL.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "Markdown content".write(to: tempURL.appendingPathComponent("file2.md"), atomically: true, encoding: .utf8)

        let subdir = tempURL.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "Nested Hello".write(to: subdir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
    }

    /// Cleanup via deinit
    func cleanup() {
        try? FileManager.default.removeItem(at: tempURL)
    }

    @Test("List Directory Tool")
    func listDirectoryTool() async throws {
        defer { cleanup() }
        let tool = ListDirectoryTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "."])

        #expect(result.success)
        let content = result.output

        #expect(content.contains("file1.txt"))
        #expect(content.contains("file2.md"))
        #expect(content.contains("subdir"))
        #expect(!content.contains("nested.txt"))
    }

    @Test("Read File Tool")
    func readFileTool() async throws {
        defer { cleanup() }
        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "file1.txt"])

        #expect(result.success)
        #expect(result.output == "Hello World")
    }

    @Test("Find File Tool")
    func findFileTool() async throws {
        defer { cleanup() }
        let tool = FindFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)

        let result = try await tool.execute(parameters: ["path": ".", "pattern": "nested"])

        #expect(result.success)
        let content = result.output

        #expect(content.contains("subdir/nested.txt"))
    }

    @Test("Search File Content Tool")
    func searchFileContentTool() async throws {
        defer { cleanup() }
        let tool = SearchFileContentTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)

        // 1. Non-recursive
        let result1 = try await tool.execute(parameters: ["path": ".", "pattern": "Hello", "recursive": false])
        #expect(result1.success)
        #expect(result1.output.contains("file1.txt"))
        #expect(!result1.output.contains("nested.txt"))

        // 2. Recursive
        let result2 = try await tool.execute(parameters: ["path": ".", "pattern": "Hello", "recursive": true])
        #expect(result2.success)
        #expect(result2.output.contains("file1.txt"))
        #expect(result2.output.contains("nested.txt"))
    }

    @Test("Search Files Tool")
    func searchFilesTool() async throws {
        defer { cleanup() }
        let tool = SearchFilesTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)

        let result = try await tool.execute(parameters: ["pattern": "Hello"])
        #expect(result.success)
        let content = result.output

        #expect(content.contains("file1.txt"))
        #expect(content.contains("subdir/nested.txt"))

        let resultInclude = try await tool.execute(parameters: ["pattern": "Hello", "include": "*.txt"])
        #expect(resultInclude.success)
        #expect(resultInclude.output.contains("file1.txt"))
        #expect(!resultInclude.output.contains("file2.md"))

        let resultSingleFile = try await tool.execute(parameters: ["pattern": "Hello", "path": "file1.txt"])
        #expect(resultSingleFile.success)
        #expect(resultSingleFile.output.contains("file1.txt"))
    }

    @Test("Search Files Tool fails when grep output exceeds resource limit")
    func searchFilesToolFailsWhenOutputLimitExceeded() async throws {
        defer { cleanup() }
        let highOutputFile = tempURL.appendingPathComponent("high-output.txt")
        let line = "needle " + String(repeating: "x", count: 120)
        try Array(repeating: line, count: 3_000)
            .joined(separator: "\n")
            .write(to: highOutputFile, atomically: true, encoding: .utf8)

        let tool = SearchFilesTool(
            currentDirectory: tempURL.path,
            jailRoot: tempURL.path,
            limits: FilesystemSearchLimits(maxOutputBytes: 1_024, maxMatches: 3_000)
        )
        let result = try await tool.execute(parameters: ["pattern": "needle", "path": "high-output.txt"])

        #expect(!result.success)
        #expect(result.error?.contains("output byte limit") == true)
    }

    @Test("Search Files Tool fails before reading files over per-file byte limit")
    func searchFilesToolFailsWhenPerFileLimitExceeded() async throws {
        defer { cleanup() }
        let largeFile = tempURL.appendingPathComponent("large-search.txt")
        try (String(repeating: "x", count: 256) + "\nneedle\n")
            .write(to: largeFile, atomically: true, encoding: .utf8)

        let tool = SearchFilesTool(
            currentDirectory: tempURL.path,
            jailRoot: tempURL.path,
            limits: FilesystemSearchLimits(maxFileBytes: 128)
        )
        let result = try await tool.execute(parameters: ["pattern": "needle", "path": "large-search.txt"])

        #expect(!result.success)
        #expect(result.error?.contains("per-file byte limit") == true)
    }

    @Test("Search Files Tool fails at file-count limit")
    func searchFilesToolFailsAtFileCountLimit() async throws {
        defer { cleanup() }
        let tool = SearchFilesTool(
            currentDirectory: tempURL.path,
            jailRoot: tempURL.path,
            limits: FilesystemSearchLimits(maxFiles: 1)
        )
        let result = try await tool.execute(parameters: ["pattern": "missing", "path": "."])

        #expect(!result.success)
        #expect(result.error?.contains("file-count limit") == true)
    }

    @Test("Search Files Tool fails at wall-clock limit")
    func searchFilesToolFailsAtWallClockLimit() async throws {
        defer { cleanup() }
        let tool = SearchFilesTool(
            currentDirectory: tempURL.path,
            jailRoot: tempURL.path,
            limits: FilesystemSearchLimits(wallClockSeconds: -1)
        )
        let result = try await tool.execute(parameters: ["pattern": "Hello", "path": "."])

        #expect(!result.success)
        #expect(result.error?.contains("timed out") == true)
    }

    @Test("Search File Content Tool fails before reading files over per-file byte limit")
    func searchFileContentToolFailsWhenPerFileLimitExceeded() async throws {
        defer { cleanup() }
        let largeFile = tempURL.appendingPathComponent("large.txt")
        let content = String(repeating: "x", count: 1_048_577) + "\nneedle\n"
        try content.write(to: largeFile, atomically: true, encoding: .utf8)

        let tool = SearchFileContentTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "large.txt", "pattern": "needle"])

        #expect(!result.success)
        #expect(result.error?.contains("per-file byte limit") == true)
    }

    @Test("Search File Content Tool fails at file-count limit")
    func searchFileContentToolFailsAtFileCountLimit() async throws {
        defer { cleanup() }
        let tool = SearchFileContentTool(
            currentDirectory: tempURL.path,
            jailRoot: tempURL.path,
            limits: FilesystemSearchLimits(maxFiles: 1)
        )
        let result = try await tool.execute(parameters: ["path": ".", "pattern": "missing", "recursive": true])

        #expect(!result.success)
        #expect(result.error?.contains("file-count limit") == true)
    }

    @Test("Search File Content Tool fails at total byte limit")
    func searchFileContentToolFailsAtTotalByteLimit() async throws {
        defer { cleanup() }
        let tool = SearchFileContentTool(
            currentDirectory: tempURL.path,
            jailRoot: tempURL.path,
            limits: FilesystemSearchLimits(maxTotalBytes: 8)
        )
        let result = try await tool.execute(parameters: ["path": ".", "pattern": "missing", "recursive": false])

        #expect(!result.success)
        #expect(result.error?.contains("total byte limit") == true)
    }

    @Test("Search File Content Tool fails at wall-clock limit")
    func searchFileContentToolFailsAtWallClockLimit() async throws {
        defer { cleanup() }
        let tool = SearchFileContentTool(
            currentDirectory: tempURL.path,
            jailRoot: tempURL.path,
            limits: FilesystemSearchLimits(wallClockSeconds: -1)
        )
        let result = try await tool.execute(parameters: ["path": ".", "pattern": "Hello", "recursive": true])

        #expect(!result.success)
        #expect(result.error?.contains("timed out") == true)
    }

    @Test("Search File Content Tool enforces match limit across files")
    func searchFileContentToolEnforcesMatchLimitAcrossFiles() async throws {
        defer { cleanup() }
        try """
        needle one
        needle two
        """.write(to: tempURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try """
        needle three
        needle four
        """.write(to: tempURL.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let tool = SearchFileContentTool(
            currentDirectory: tempURL.path,
            jailRoot: tempURL.path,
            limits: FilesystemSearchLimits(maxMatches: 3)
        )
        let result = try await tool.execute(parameters: ["path": ".", "pattern": "needle", "recursive": false])

        #expect(result.success)
        let outputLines = result.output
            .split(separator: "\n")
            .filter { $0.contains("needle") }
        #expect(outputLines.count == 3)
    }

    @Test("Path Traversal Protection")
    func pathTraversalProtection() async throws {
        defer { cleanup() }
        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)

        let outsideFile = FileManager.default.temporaryDirectory.appendingPathComponent("outside_\(UUID().uuidString).txt")
        try "Secret Data".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let relativePathOutside = "../\(outsideFile.lastPathComponent)"

        let result = try await tool.execute(parameters: ["path": AnyCodable(relativePathOutside)])

        #expect(!result.success)
        #expect(result.error != nil)
    }

    @Test("Jailed Relative Path")
    func jailedRelativePath() async throws {
        defer { cleanup() }
        let subdir = tempURL.appendingPathComponent("subdir")
        let tool = ListDirectoryTool(currentDirectory: subdir.path, jailRoot: tempURL.path)

        let result = try await tool.execute(parameters: ["path": ".."])

        #expect(result.success)
        #expect(result.output.contains("file1.txt"))

        let resultOutside = try await tool.execute(parameters: ["path": "../../.."])
        #expect(!resultOutside.success)
    }

    @Test("Sibling prefix path is outside jail")
    func siblingPrefixPathIsOutsideJail() async throws {
        defer { cleanup() }
        let siblingURL = URL(fileURLWithPath: tempURL.path + "-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: siblingURL) }

        let secretURL = siblingURL.appendingPathComponent("secret.txt")
        try "Secret Data".write(to: secretURL, atomically: true, encoding: .utf8)

        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": AnyCodable(secretURL.path)])

        #expect(!result.success)
    }

    @Test("Absolute path inside jail is allowed")
    func absolutePathInsideJailIsAllowed() async throws {
        defer { cleanup() }
        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)

        let result = try await tool.execute(parameters: ["path": AnyCodable(tempURL.appendingPathComponent("file1.txt").path)])

        #expect(result.success)
        #expect(result.output == "Hello World")
    }

    @Test("Absolute path outside jail is rejected")
    func absolutePathOutsideJailIsRejected() async throws {
        defer { cleanup() }
        let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent("outside_\(UUID().uuidString).txt")
        try "Secret Data".write(to: outsideURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": AnyCodable(outsideURL.path)])

        #expect(!result.success)
    }

    @Test("Symlink inside jail pointing outside is rejected")
    func symlinkInsideJailPointingOutsideIsRejected() async throws {
        defer { cleanup() }
        let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent("outside_\(UUID().uuidString).txt")
        try "Secret Data".write(to: outsideURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        let linkURL = tempURL.appendingPathComponent("outside-link.txt")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "outside-link.txt"])

        #expect(!result.success)
    }

    @Test("Symlink inside jail pointing inside is allowed")
    func symlinkInsideJailPointingInsideIsAllowed() async throws {
        defer { cleanup() }
        let linkURL = tempURL.appendingPathComponent("inside-link.txt")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: tempURL.appendingPathComponent("file1.txt")
        )

        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: ["path": "inside-link.txt"])

        #expect(result.success)
        #expect(result.output == "Hello World")
    }

    // MARK: - Stray workspaceID tolerance (PKPOST-004b)

    @Test("ReadFileTool tolerates stray workspaceID argument")
    func readFileToolToleratesStrayWorkspaceID() async throws {
        defer { cleanup() }
        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: [
            "path": "file1.txt",
            "workspaceID": "08573919-5c5e-4fb9-9285-352a8c88f7ab",
        ])

        #expect(result.success)
        #expect(result.output == "Hello World")
    }

    @Test("ListDirectoryTool tolerates stray workspaceID argument")
    func listDirectoryToolToleratesStrayWorkspaceID() async throws {
        defer { cleanup() }
        let tool = ListDirectoryTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: [
            "path": ".",
            "workspaceID": "08573919-5c5e-4fb9-9285-352a8c88f7ab",
        ])

        #expect(result.success)
        #expect(result.output.contains("file1.txt"))
    }

    @Test("FindFileTool tolerates stray workspaceID argument")
    func findFileToolToleratesStrayWorkspaceID() async throws {
        defer { cleanup() }
        let tool = FindFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: [
            "path": ".",
            "pattern": "nested",
            "workspaceID": "08573919-5c5e-4fb9-9285-352a8c88f7ab",
        ])

        #expect(result.success)
        #expect(result.output.contains("subdir/nested.txt"))
    }

    @Test("SearchFilesTool tolerates stray workspaceID argument")
    func searchFilesToolToleratesStrayWorkspaceID() async throws {
        defer { cleanup() }
        let tool = SearchFilesTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: [
            "pattern": "Hello",
            "workspaceID": "08573919-5c5e-4fb9-9285-352a8c88f7ab",
        ])

        #expect(result.success)
        #expect(result.output.contains("file1.txt"))
    }

    @Test("SearchFileContentTool tolerates stray workspaceID argument")
    func searchFileContentToolToleratesStrayWorkspaceID() async throws {
        defer { cleanup() }
        let tool = SearchFileContentTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)
        let result = try await tool.execute(parameters: [
            "path": ".",
            "pattern": "Hello",
            "recursive": false,
            "workspaceID": "08573919-5c5e-4fb9-9285-352a8c88f7ab",
        ])

        #expect(result.success)
        #expect(result.output.contains("file1.txt"))
    }
}
