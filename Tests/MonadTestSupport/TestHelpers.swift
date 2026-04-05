import Foundation
import MonadCore
import MonadShared

#if DEBUG
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("com.monad.test-workspaces")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Auto-cleaning temporary workspace directory for tests.
    ///
    /// When the instance is deallocated, the directory is removed.
    /// Use as a stored property in your test suite:
    /// ```swift
    /// @Suite struct MyTests {
    ///     let workspace = TestWorkspace()
    ///     @Test func example() async throws {
    ///         let manager = TimelineManager(workspaceRoot: workspace.root)
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
#endif
