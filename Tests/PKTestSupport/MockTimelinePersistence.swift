import Foundation
import PKShared
import PKUtilities
import PositronicKit
import struct PositronicKit.Thread
import Synchronization

/// In-memory `ThreadPersistenceProtocol` test double backed by a mutex-guarded array.
///
/// Inspectable: `threads` reads/writes the backing store directly. `fetchAllThreads`
/// filters out archived threads unless `includeArchived` is `true`. `pruneThreads`
/// is a no-op that always reports zero pruned rows.
public final class MockThreadPersistenceStore: ThreadPersistenceProtocol, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private let threadsState = Mutex<[Thread]>([])

    public var threads: [Thread] {
        get { threadsState.withLock { $0 } }
        set { threadsState.withLock { $0 = newValue } }
    }

    public init() {}

    public func saveThread(_ thread: Thread) async throws {
        threadsState.withLock {
            if let index = $0.firstIndex(where: { $0.id == thread.id }) {
                $0[index] = thread
            } else {
                $0.append(thread)
            }
        }
    }

    public func fetchThread(id: UUID) async throws -> Thread? {
        threadsState.withLock {
            $0.first { $0.id == id }
        }
    }

    public func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        threadsState.withLock {
            includeArchived ? $0 : $0.filter { !$0.isArchived }
        }
    }

    public func deleteThread(id: UUID) async throws {
        threadsState.withLock {
            $0.removeAll { $0.id == id }
        }
    }

    public func pruneThreads(olderThan _: TimeInterval, excluding _: [UUID], dryRun _: Bool) async throws -> Int {
        return 0
    }
}

/// Actor-backed canonical persistence test double used for compatibility coverage.
public actor MockThreadPersistence: ThreadPersistenceProtocol {
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
        includeArchived ? threads : threads.filter { !$0.isArchived }
    }

    public func deleteThread(id: UUID) async throws {
        threads.removeAll { $0.id == id }
    }

    public func pruneThreads(
        olderThan _: TimeInterval,
        excluding _: [UUID],
        dryRun _: Bool
    ) async throws -> Int {
        0
    }
}
