import Foundation
import PKShared
import PKUtilities

/// Thread-safe in-memory thread persistence for prototyping and development.
public actor InMemoryThreadPersistence: ThreadPersistenceProtocol {
    private var threads: [Thread] = []

    public init() {}

    public func saveThread(_ thread: Thread) async throws {
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.append(thread)
        }
    }

    public func fetchThread(id: UUID) async throws -> Thread? {
        threads.first { $0.id == id }
    }

    public func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        if includeArchived {
            return threads
        } else {
            return threads.filter { !$0.isArchived }
        }
    }

    public func deleteThread(id: UUID) async throws {
        threads.removeAll { $0.id == id }
    }

    public func pruneThreads(olderThan _: TimeInterval, excluding _: [UUID], dryRun _: Bool) async throws -> Int {
        0
    }

    package func allThreads() -> [Thread] {
        threads
    }

    package func replaceThreads(_ threads: [Thread]) {
        self.threads = threads
    }

}
