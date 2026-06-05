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

    @Test("Path Traversal Protection")
    func pathTraversalProtection() async throws {
        defer { cleanup() }
        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)

        let outsideFile = FileManager.default.temporaryDirectory.appendingPathComponent("outside_\(UUID().uuidString).txt")
        try "Secret Data".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let relativePathOutside = "../\(outsideFile.lastPathComponent)"

        let result = try await tool.execute(parameters: ["path": relativePathOutside])

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
        let result = try await tool.execute(parameters: ["path": secretURL.path])

        #expect(!result.success)
    }

    @Test("Absolute path inside jail is allowed")
    func absolutePathInsideJailIsAllowed() async throws {
        defer { cleanup() }
        let tool = ReadFileTool(currentDirectory: tempURL.path, jailRoot: tempURL.path)

        let result = try await tool.execute(parameters: ["path": tempURL.appendingPathComponent("file1.txt").path])

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
        let result = try await tool.execute(parameters: ["path": outsideURL.path])

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
}
