import Foundation
import PKTestSupport
import Testing

@Suite("MockLocalWorkspace")
final class MockLocalWorkspaceTests {
    private var tempDir: URL!
    private var workspace: MockLocalWorkspace!

    init() async throws {
        let tempDirPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: tempDirPath, withIntermediateDirectories: true)
        tempDir = URL(fileURLWithPath: tempDirPath)
        workspace = MockLocalWorkspace(rootURL: tempDir)
    }

    deinit {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    @Test("readFile rejects path traversal attacks")
    func readFileRejectsTraversal() async throws {
        do {
            _ = try await workspace.readFile(path: "../outside")
            Issue.record("Expected readFile to throw when given a traversal path")
        } catch {
            // Expected: should throw when path tries to escape the root
        }
    }

    @Test("writeFile rejects path traversal attacks")
    func writeFileRejectsTraversal() async throws {
        do {
            try await workspace.writeFile(path: "../outside", content: "x")
            Issue.record("Expected writeFile to throw when given a traversal path")
        } catch {
            // Expected: should throw when path tries to escape the root
        }
    }

    @Test("deleteFile rejects path traversal attacks")
    func deleteFileRejectsTraversal() async throws {
        do {
            try await workspace.deleteFile(path: "../outside")
            Issue.record("Expected deleteFile to throw when given a traversal path")
        } catch {
            // Expected: should throw when path tries to escape the root
        }
    }

    @Test("readFile accepts and reads files within the root")
    func readFileAcceptsSafePath() async throws {
        let testFilename = "test.txt"
        let testContent = "Hello, World!"

        // Write a file directly to the temp directory
        let fileURL = tempDir.appendingPathComponent(testFilename)
        try testContent.write(to: fileURL, atomically: true, encoding: .utf8)

        // Read it back through the workspace
        let readContent = try await workspace.readFile(path: testFilename)
        #expect(readContent == testContent)
    }

    @Test("writeFile accepts and creates files within the root")
    func writeFileAcceptsSafePath() async throws {
        let testFilename = "created.txt"
        let testContent = "Created by test"

        // Write through the workspace
        try await workspace.writeFile(path: testFilename, content: testContent)

        // Verify the file was created
        let fileURL = tempDir.appendingPathComponent(testFilename)
        let readBack = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(readBack == testContent)
    }

    @Test("deleteFile accepts and deletes files within the root")
    func deleteFileAcceptsSafePath() async throws {
        let testFilename = "to_delete.txt"

        // Create a file
        let fileURL = tempDir.appendingPathComponent(testFilename)
        try "delete me".write(to: fileURL, atomically: true, encoding: .utf8)

        // Delete it through the workspace
        try await workspace.deleteFile(path: testFilename)

        // Verify it was deleted
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("listFiles scopes enumeration to the requested subdirectory")
    func listFilesScopesToRequestedPath() async throws {
        // Root-level file, which should NOT be returned when listing a subdirectory.
        try "root".write(to: tempDir.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)

        // Subdirectory with its own file, which SHOULD be returned when listing that subdirectory.
        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "nested".write(to: subDir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

        // Returned paths stay root-relative (not relative to the requested `path`) because callers
        // Context discovery consumers feed listFiles' output straight into readFile/writeFile, which
        // resolve paths relative to the workspace root.
        let scoped = try await workspace.listFiles(path: "sub")
        #expect(scoped == ["sub/nested.txt"])

        let rootListing = try await workspace.listFiles(path: ".")
        #expect(Set(rootListing) == Set(["root.txt", "sub/nested.txt"]))
    }
}
