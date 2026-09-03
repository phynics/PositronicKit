import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import struct PositronicKit.Thread
import Testing

private actor AttachmentThreadPersistence: ThreadPersistenceProtocol {
    private let backing = MockThreadPersistence()
    private var saveFails = false

    func setSaveFails(_ value: Bool) {
        saveFails = value
    }

    func saveThread(_ thread: Thread) async throws {
        if saveFails { throw FailingStoreError.saveFailed }
        try await backing.saveThread(thread)
    }

    func fetchThread(id: UUID) async throws -> Thread? {
        try await backing.fetchThread(id: id)
    }

    func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        try await backing.fetchAllThreads(includeArchived: includeArchived)
    }

    func deleteThread(id: UUID) async throws {
        try await backing.deleteThread(id: id)
    }

    func pruneThreads(
        olderThan timeInterval: TimeInterval,
        excluding excludedThreadIds: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await backing.pruneThreads(
            olderThan: timeInterval,
            excluding: excludedThreadIds,
            dryRun: dryRun
        )
    }
}

private actor BlockingWorkspaceStore: WorkspaceStore {
    private var workspaces: [UUID: WorkspaceReference] = [:]
    private var validationStarted = false
    private var validationStartedContinuation: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- Mutex/actor lifecycle state machine (see docs/Concurrency/exception-manifest.md)
    private var validationContinuation: CheckedContinuation<WorkspaceReference?, Never>? // swiftlint:disable:this concurrency_stored_continuation -- Mutex/actor lifecycle state machine (see docs/Concurrency/exception-manifest.md)
    private var validationWorkspaceID: UUID?

    func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        workspaces[workspace.id] = workspace
    }

    func fetchWorkspace(id: UUID, includeTools _: Bool) async throws -> WorkspaceReference? {
        validationStarted = true
        validationStartedContinuation?.resume()
        validationStartedContinuation = nil
        validationWorkspaceID = id
        return await withCheckedContinuation { continuation in
            validationContinuation = continuation
        }
    }

    func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        Array(workspaces.values)
    }

    func deleteWorkspace(id: UUID) async throws {
        workspaces.removeValue(forKey: id)
    }

    func waitUntilValidationStarts() async {
        guard !validationStarted else { return }
        await withCheckedContinuation { continuation in
            validationStartedContinuation = continuation
        }
    }

    func releaseValidation() {
        let workspace = validationWorkspaceID.flatMap { workspaces[$0] }
        validationWorkspaceID = nil
        validationContinuation?.resume(returning: workspace)
        validationContinuation = nil
    }
}

/// PKRR-007: Thread creation and workspace attachment must not leave partial state.
///
/// `createThread` persists the thread record first, then creates ancillary state
/// (directory, notes, workspace row, in-memory caches). If any step fails, all
/// previously created state is rolled back before rethrowing.
///
/// `attachWorkspace` validates the workspace exists in the store before persisting the
/// attachment. If validation fails, the thread is not mutated.
///
/// These tests inject failures at each step and assert no orphan directories, workspace
/// rows, cached managers, or persisted attachment IDs remain.
@Suite("Thread lifecycle fault injection (PKRR-007)")
struct ThreadLifecycleFaultInjectionTests {

    @Test("attachWorkspace does not resurrect a permanently deleted thread")
    func attachWorkspaceDoesNotResurrectPermanentlyDeletedThread() async throws {
        let threadStore = MockPersistenceService()
        let workspaceStore = BlockingWorkspaceStore()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        try await workspaceStore.saveWorkspace(workspace)

        let manager = ThreadManager(
            stores: .init(
                threadStore: threadStore,
                messageStore: threadStore,
                workspaceStore: workspaceStore,
                runtimeRepository: threadStore,
                toolPersistence: threadStore
            ),
            workspaceProfile: .noWorkspace
        )
        let thread = try await manager.createThread()

        let attachTask = Task {
            try? await manager.attachWorkspace(workspace.id, to: thread.id)
        }
        await workspaceStore.waitUntilValidationStarts()

        let deleteTask = Task {
            await manager.deleteThreadPermanently(id: thread.id)
        }
        let deletion = await deleteTask.value
        #expect(deletion.isComplete)
        #expect(try await threadStore.fetchThread(id: thread.id) == nil)

        await workspaceStore.releaseValidation()
        _ = await attachTask.value

        #expect(try await threadStore.fetchThread(id: thread.id) == nil)
    }

    @Test("attachment store failure does not mutate the cached thread")
    func attachmentStoreFailureDoesNotMutateCachedThread() async throws {
        let threadStore = AttachmentThreadPersistence()
        let persistence = MockPersistenceService()
        let manager = ThreadManager(
            stores: .init(
                threadStore: threadStore,
                messageStore: persistence,
                workspaceStore: persistence,
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                toolPersistence: persistence
            ),
            workspaceProfile: .noWorkspace
        )
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        try await persistence.saveWorkspace(workspace)

        let thread = try await manager.createThread()
        let original = try #require(await manager.thread(id: thread.id))

        await threadStore.setSaveFails(true)
        do {
            try await manager.attachWorkspace(workspace.id, to: thread.id)
            Issue.record("Expected attach save to fail")
        } catch FailingStoreError.saveFailed {
            // Expected.
        }

        let afterAttachFailure = try #require(await manager.thread(id: thread.id))
        #expect(afterAttachFailure.updatedAt == original.updatedAt)

        await threadStore.setSaveFails(false)
        try await manager.attachWorkspace(workspace.id, to: thread.id)
        let attached = try #require(await manager.thread(id: thread.id))

        await threadStore.setSaveFails(true)
        do {
            try await manager.detachWorkspace(workspace.id, from: thread.id)
            Issue.record("Expected detach save to fail")
        } catch FailingStoreError.saveFailed {
            // Expected.
        }

        let afterDetachFailure = try #require(await manager.thread(id: thread.id))
        #expect(afterDetachFailure.updatedAt == attached.updatedAt)
    }

    // MARK: - createThread: thread store failure leaves no orphan state

    @Test("createThread rolls back when the thread store fails on save")
    func createThreadRollsBackOnThreadStoreFailure() async throws {
        let persistence = MockPersistenceService()
        let failingThreadStore = FailingThreadPersistence(saveFails: true)
        let workspaceStore = MockWorkspacePersistence()
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: failingThreadStore,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        do {
            _ = try await manager.createThread(title: "Failing Thread")
            Issue.record("Expected ThreadError.unavailable")
        } catch ThreadError.unavailable {
            // Correct — the store failure is surfaced.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(workspaceStore.workspaces.isEmpty,
               "No workspace row should be left when the thread store fails")
        #expect(persistence.threads.isEmpty,
               "No thread record should be left in the message store")
        #expect(await manager.thread(id: UUID()) == nil,
               "No thread should be cached in memory")
    }

    @Test("createThread rolls back when the workspace store fails on save")
    func createThreadRollsBackOnWorkspaceStoreFailure() async throws {
        let persistence = MockPersistenceService()
        let failingWorkspaceStore = FailingWorkspaceStore(saveFails: true)
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: failingWorkspaceStore,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        var createdThreadId: UUID?
        do {
            let thread = try await manager.createThread(title: "WS Fail Thread")
            createdThreadId = thread.id
        } catch ThreadError.unavailable {
            // Correct — the workspace store failure is surfaced.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(createdThreadId == nil, "createThread should not return a thread on failure")

        let threadsInStore = persistence.threads
        #expect(threadsInStore.isEmpty,
               "No thread record should persist when the workspace store fails")

        let threadsDir = workspace.root.appendingPathComponent("threads", isDirectory: true)
        if FileManager.default.fileExists(atPath: threadsDir.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: threadsDir.path)
            #expect(contents.isEmpty,
                    "No thread directory should remain when the workspace store fails")
        }

        #expect(failingWorkspaceStore.saveAttemptCount >= 1,
               "The workspace store save must have been attempted")
    }

    @Test("createThread succeeds when all stores are healthy and leaves no orphans")
    func createThreadHealthyLeavesNoOrphans() async throws {
        let persistence = MockPersistenceService()
        let workspaceStore = MockWorkspacePersistence()
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let thread = try await manager.createThread(title: "Healthy Thread")

        let persistedThread = try #require(await persistence.fetchThread(id: thread.id))
        #expect(persistedThread.id == thread.id)

        #expect(workspaceStore.workspaces.count == 1,
               "Exactly one workspace should be saved for a healthy thread")
        let workspaces = try await manager.getWorkspaces(for: thread.id)
        #expect(workspaces.primary?.id == workspaceStore.workspaces.first?.id)

        let workingDir = try #require(thread.workingDirectory)
        #expect(FileManager.default.fileExists(atPath: workingDir),
               "The working directory should exist")

        let cached = await manager.thread(id: thread.id)
        #expect(cached != nil, "The thread should be cached in memory")
    }

    // MARK: - createThread: directory or filesystem failure rollback

    @Test("createThread rolls back the thread record when directory creation fails")
    func createThreadRollsBackOnDirectoryFailure() async throws {
        let persistence = MockPersistenceService()
        let workspaceStore = MockWorkspacePersistence()
        let workspace = TestWorkspace()

        let invalidRoot = workspace.root.appendingPathComponent("invalid")
        try Data().write(to: invalidRoot)

        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: invalidRoot)
        )

        do {
            _ = try await manager.createThread(title: "Dir Fail Thread")
            Issue.record("Expected an error")
        } catch {
            // Expected — either ThreadError.unavailable or a filesystem error
        }

        let threadsInStore = persistence.threads
        #expect(threadsInStore.allSatisfy { $0.title != "Dir Fail Thread" },
               "No thread record with the failing title should persist")
        #expect(workspaceStore.workspaces.isEmpty,
               "No workspace row should be left when directory creation fails")
    }

    // MARK: - attachWorkspace: workspace validation before persistence

    @Test("attachWorkspace throws and does not mutate the thread when the workspace does not exist")
    func attachWorkspaceRejectsMissingWorkspace() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let thread = try await manager.createThread()
        let missingWorkspaceId = UUID()

        do {
            try await manager.attachWorkspace(missingWorkspaceId, to: thread.id)
            Issue.record("Expected ThreadError.invalidState")
        } catch ThreadError.invalidState {
            // Correct — the workspace does not exist.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let workspaces = try await manager.getWorkspaces(for: thread.id)
        #expect(!workspaces.attached.contains { $0.id == missingWorkspaceId },
               "The missing workspace ID must not be bound")
    }

    @Test("attachWorkspace throws and does not mutate the thread when the workspace store fails")
    func attachWorkspaceRejectsOnStoreFailure() async throws {
        let persistence = MockPersistenceService()
        let failingWorkspaceStore = FailingWorkspaceStore(fetchFails: true)
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: failingWorkspaceStore,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let thread = try await manager.createThread()
        let workspaceId = UUID()

        do {
            try await manager.attachWorkspace(workspaceId, to: thread.id)
            Issue.record("Expected ThreadError.unavailable")
        } catch ThreadError.unavailable {
            // Correct — the store failure is surfaced.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let workspaces = try await manager.getWorkspaces(for: thread.id)
        #expect(workspaces.attached.isEmpty)
    }

    @Test("attachWorkspace persists the attachment when the workspace exists")
    func attachWorkspaceSucceedsWhenWorkspaceExists() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let thread = try await manager.createThread()
        let attachedWS = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        try await persistence.saveWorkspace(attachedWS)

        try await manager.attachWorkspace(attachedWS.id, to: thread.id)

        let workspaces = try await manager.getWorkspaces(for: thread.id)
        #expect(workspaces.attached.contains { $0.id == attachedWS.id },
               "The workspace binding should be persisted in the repository")
    }

    // MARK: - attachWorkspace: already-attached workspace is re-validated

    @Test("attachWorkspace re-validates an already-attached workspace and throws if it was deleted")
    func attachWorkspaceRevalidatesAlreadyAttached() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let thread = try await manager.createThread()
        let attachedWS = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        try await persistence.saveWorkspace(attachedWS)
        try await manager.attachWorkspace(attachedWS.id, to: thread.id)

        try await persistence.deleteWorkspace(id: attachedWS.id)

        do {
            try await manager.attachWorkspace(attachedWS.id, to: thread.id)
            Issue.record("Expected ThreadError.invalidState after workspace deletion")
        } catch ThreadError.invalidState {
            // Correct — the workspace no longer exists.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let workspaces = try await manager.getWorkspaces(for: thread.id)
        #expect(!workspaces.attached.contains { $0.id == attachedWS.id },
               "The deleted workspace should not be re-attached")
    }

    // MARK: - createThread: retry after failure succeeds (no stale state)

    @Test("createThread can be retried after a transient store failure")
    func createThreadRetryAfterFailure() async throws {
        let persistence = MockPersistenceService()
        let failingThreadStore = FailingThreadPersistence(saveFails: true)
        let workspaceStore = MockWorkspacePersistence()
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: failingThreadStore,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        do {
            _ = try await manager.createThread(title: "First Attempt")
        } catch {
            // Expected
        }

        #expect(workspaceStore.workspaces.isEmpty,
               "No orphan workspace after first failure")

        let healthyStore = MockThreadPersistence()
        let healthyManager = ThreadManager(
            stores: .init(
                threadStore: healthyStore,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let thread = try await healthyManager.createThread(title: "Retry Attempt")
        #expect(thread.title == "Retry Attempt")

        let persisted = try #require(await healthyStore.fetchThread(id: thread.id))
        #expect(persisted.id == thread.id)
        #expect(workspaceStore.workspaces.count == 1,
               "Exactly one workspace after the successful retry")
    }
}
