import Foundation
import PKShared
import PKUtilities
import PositronicKit
import struct PositronicKit.Thread
import Synchronization

/// Error thrown by the failing persistence mocks to simulate store failures in
/// failure-path tests.
public enum FailingStoreError: Error, Sendable {
    case saveFailed
    case fetchFailed
    case deleteFailed
}

/// A `ThreadMessageStoreProtocol` mock that throws on `saveMessage` while recording each
/// attempted message, so failure-path tests can assert the save was both attempted
/// and non-fatal to the caller (e.g. an audit-log save that the caller must survive).
public final class FailingMessageStore: ThreadMessageStoreProtocol, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private let attemptedState = Mutex<[ConversationMessage]>([])

    /// Messages handed to `saveMessage` before it threw, in arrival order.
    public var attemptedMessages: [ConversationMessage] {
        attemptedState.withLock { $0 }
    }

    public init() {}

    public func saveMessage(_ message: ConversationMessage) async throws {
        attemptedState.withLock { $0.append(message) }
        throw FailingStoreError.saveFailed
    }

    public func fetchMessages(for threadID: UUID) async throws -> [ConversationMessage] { [] }

    public func deleteMessages(for threadID: UUID) async throws {}

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int { 0 }

    public func fetchSnapshots(for threadID: UUID) async throws -> [TurnSnapshot] { [] }
}

/// A `ThreadPersistenceProtocol` mock that can be configured to throw on
/// `fetchThread`, `saveThread`, and/or `deleteThread`, delegating all other
/// operations to an in-memory backing store. Use it to drive failure-path coverage
/// for hydration (`fetchThread`) and private-thread cleanup (`deleteThread`).
public final class FailingThreadPersistence: ThreadPersistenceProtocol, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private let backing = MockThreadPersistenceStore()
    private let fetchFails: Bool
    private let saveFails: Bool
    private let deleteFails: Bool
    private let fetchAttemptState = Mutex<Int>(0)
    private let deleteAttemptState = Mutex<Int>(0)

    public init(
        fetchFails: Bool = false,
        saveFails: Bool = false,
        deleteFails: Bool = false
    ) {
        self.fetchFails = fetchFails
        self.saveFails = saveFails
        self.deleteFails = deleteFails
    }

    /// Number of times `fetchThread` was invoked.
    public var fetchAttemptCount: Int { fetchAttemptState.withLock { $0 } }

    /// Number of times `deleteThread` was invoked.
    public var deleteAttemptCount: Int { deleteAttemptState.withLock { $0 } }

    public func saveThread(_ thread: Thread) async throws {
        if saveFails { throw FailingStoreError.saveFailed }
        try await backing.saveThread(thread)
    }

    public func fetchThread(id: UUID) async throws -> Thread? {
        fetchAttemptState.withLock { $0 += 1 }
        if fetchFails { throw FailingStoreError.fetchFailed }
        return try await backing.fetchThread(id: id)
    }

    public func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        try await backing.fetchAllThreads(includeArchived: includeArchived)
    }

    public func deleteThread(id: UUID) async throws {
        deleteAttemptState.withLock { $0 += 1 }
        if deleteFails { throw FailingStoreError.deleteFailed }
        try await backing.deleteThread(id: id)
    }

    public func pruneThreads(
        olderThan timeInterval: TimeInterval,
        excluding excludedThreadIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await backing.pruneThreads(
            olderThan: timeInterval,
            excluding: excludedThreadIDs,
            dryRun: dryRun
        )
    }
}

/// A `WorkspaceStore` mock that can be configured to throw on `fetchWorkspace` and/or
/// `saveWorkspace`, delegating all other operations to an in-memory backing store. Use it
/// to drive failure-path coverage for workspace resolution in `getWorkspaces`,
/// `setupThreadComponents`, and lifecycle rollback in `createThread`/`attachWorkspace`.
public final class FailingWorkspaceStore: WorkspaceStore, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private let backing = MockWorkspacePersistence()
    private let fetchFailsState = Mutex<Bool>(false)
    private let saveFails: Bool
    private let fetchAttemptState = Mutex<Int>(0)
    private let saveAttemptState = Mutex<Int>(0)

    public init(fetchFails: Bool = false, saveFails: Bool = false) {
        self.fetchFailsState.withLock { $0 = fetchFails }
        self.saveFails = saveFails
    }

    public var fetchFails: Bool {
        get { fetchFailsState.withLock { $0 } }
        set { fetchFailsState.withLock { $0 = newValue } }
    }

    public var fetchAttemptCount: Int { fetchAttemptState.withLock { $0 } }
    public var saveAttemptCount: Int { saveAttemptState.withLock { $0 } }

    public var workspaces: [WorkspaceReference] {
        backing.workspaces
    }

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        saveAttemptState.withLock { $0 += 1 }
        if saveFails { throw FailingStoreError.saveFailed }
        try await backing.saveWorkspace(workspace)
    }

    public func fetchWorkspace(id: UUID, includeTools: Bool) async throws -> WorkspaceReference? {
        fetchAttemptState.withLock { $0 += 1 }
        if fetchFailsState.withLock({ $0 }) { throw FailingStoreError.fetchFailed }
        return try await backing.fetchWorkspace(id: id, includeTools: includeTools)
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        try await backing.fetchAllWorkspaces()
    }

    public func deleteWorkspace(id: UUID) async throws {
        try await backing.deleteWorkspace(id: id)
    }
}

/// A `ThreadMessageStoreProtocol` mock backed by `MockMessageStore` that can be configured to
/// fail after a configurable number of successful `saveMessage` calls. Use it to drive
/// partial-batch / resumable-persistence tests (PKRR-006): set `failAfterSaveCount` to `N`
/// and the `(N+1)`-th save throws `FailingStoreError.saveFailed`. Set it back to `nil` to
/// stop failing so a retry can complete the batch. The call count and threshold are evaluated in
/// one mutex transaction, so exactly a configured nonnegative `N` concurrently admitted calls
/// reach the backing store.
public final class BatchFailingMessageStore: ThreadMessageStoreProtocol {
    private struct SaveState: Sendable {
        var failAfterSaveCount: Int?
        var saveCallCount = 0
    }

    private let backing = MockMessageStore()
    private let saveState = Mutex(SaveState())

    public init() {}

    /// When non-nil, `saveMessage` throws after this many successful saves. Set to `nil`
    /// to disable failure (e.g. for retry assertions).
    public var failAfterSaveCount: Int? {
        get { saveState.withLock { $0.failAfterSaveCount } }
        set { saveState.withLock { $0.failAfterSaveCount = newValue } }
    }

    /// Number of `saveMessage` calls received so far.
    public var saveCallCount: Int { saveState.withLock { $0.saveCallCount } }

    public var messages: [ConversationMessage] {
        backing.messages
    }

    public func saveMessage(_ message: ConversationMessage) async throws {
        let isAdmitted = saveState.withLock { state in
            state.saveCallCount += 1
            guard let limit = state.failAfterSaveCount else { return true }
            return state.saveCallCount <= limit
        }
        if !isAdmitted {
            throw FailingStoreError.saveFailed
        }
        try await backing.saveMessage(message)
    }

    public func fetchMessages(for threadID: UUID) async throws -> [ConversationMessage] {
        try await backing.fetchMessages(for: threadID)
    }

    public func deleteMessages(for threadID: UUID) async throws {
        try await backing.deleteMessages(for: threadID)
    }

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int { 0 }

    public func fetchSnapshots(for threadID: UUID) async throws -> [TurnSnapshot] { [] }
}

/// A `ToolPersistenceProtocol` mock that can be configured to throw on
/// `fetchToolSource`, delegating all other operations to an in-memory backing store.
/// Use it to drive failure-path coverage for `getToolSource`.
public final class FailingToolPersistence: ToolPersistenceProtocol, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private let backing = MockToolPersistence()
    private let fetchSourceFails: Bool
    private let fetchSourceAttemptState = Mutex<Int>(0)

    public init(fetchSourceFails: Bool = false) {
        self.fetchSourceFails = fetchSourceFails
    }

    public var fetchSourceAttemptCount: Int { fetchSourceAttemptState.withLock { $0 } }

    public func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws {
        try await backing.addToolToWorkspace(workspaceId: workspaceId, tool: tool)
    }

    public func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws {
        try await backing.syncTools(workspaceId: workspaceId, tools: tools)
    }

    public func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference] {
        try await backing.fetchTools(forWorkspaces: workspaceIds)
    }

    public func fetchOriginTools(originId: UUID) async throws -> [ToolReference] {
        try await backing.fetchOriginTools(originId: originId)
    }

    public func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID? {
        try await backing.findWorkspaceId(forToolId: toolId, in: workspaceIds)
    }

    public func fetchToolSource(
        toolId: String,
        workspaceIds: [UUID],
        primaryWorkspaceId: UUID?
    ) async throws -> String? {
        fetchSourceAttemptState.withLock { $0 += 1 }
        if fetchSourceFails { throw FailingStoreError.fetchFailed }
        return try await backing.fetchToolSource(
            toolId: toolId,
            workspaceIds: workspaceIds,
            primaryWorkspaceId: primaryWorkspaceId
        )
    }
}

/// Deprecated fixture spelling retained for tests that exercise the v3 persistence protocol.
