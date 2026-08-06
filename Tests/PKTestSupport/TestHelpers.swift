import Foundation
import PositronicKit
import PKShared
import PKUtilities

    public extension AsyncStream {
        /// Collects all elements of the stream into an array.
        /// Only works for finite streams.
        func collect() async -> [Element] {
            var result: [Element] = []
            for await element in self {
                result.append(element)
            }
            return result
        }
    }

    public extension AsyncThrowingStream {
        /// Collects all elements of the stream into an array.
        /// Only works for finite streams.
        func collect() async throws -> [Element] {
            var result: [Element] = []
            for try await element in self {
                result.append(element)
            }
            return result
        }
    }

    public func getTestWorkspaceRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("com.positronickit.test-workspaces")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Auto-cleaning temporary workspace directory for tests.
    ///
    /// The initializer creates a unique directory. Deinitialization removes it best-effort, so
    /// retain the `TestWorkspace` object—not only `root`—for as long as the directory is needed.
    /// Use as a stored property in your test suite:
    /// ```swift
    /// @Suite struct MyTests {
    ///     let workspace = TestWorkspace()
    ///     @Test func example() async throws {
    ///         let runtime = TestRuntime(workspaceRoot: workspace.root)
    ///     }
    /// }
    /// ```
    public final class TestWorkspace: @unchecked Sendable {
        public let root: URL

        public init() {
            root = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }
