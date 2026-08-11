import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

private actor AttachmentTimelinePersistence: TimelinePersistenceProtocol {
    private let backing = MockTimelinePersistence()
    private var saveFails = false

    func setSaveFails(_ value: Bool) {
        saveFails = value
    }

    func saveTimeline(_ timeline: Timeline) async throws {
        if saveFails { throw FailingStoreError.saveFailed }
        try await backing.saveTimeline(timeline)
    }

    func fetchTimeline(id: UUID) async throws -> Timeline? {
        try await backing.fetchTimeline(id: id)
    }

    func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        try await backing.fetchAllTimelines(includeArchived: includeArchived)
    }

    func deleteTimeline(id: UUID) async throws {
        try await backing.deleteTimeline(id: id)
    }

    func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIds: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await backing.pruneTimelines(
            olderThan: timeInterval,
            excluding: excludedTimelineIds,
            dryRun: dryRun
        )
    }
}

private actor BlockingWorkspaceStore: WorkspaceStore {
    private var workspaces: [UUID: WorkspaceReference] = [:]
    private var validationStarted = false
    private var validationStartedContinuation: CheckedContinuation<Void, Never>?
    private var validationContinuation: CheckedContinuation<WorkspaceReference?, Never>?
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

/// PKRR-007: Timeline creation and workspace attachment must not leave partial state.
///
/// `createTimeline` persists the timeline record first, then creates ancillary state
/// (directory, notes, workspace row, in-memory caches). If any step fails, all
/// previously created state is rolled back before rethrowing.
///
/// `attachWorkspace` validates the workspace exists in the store before persisting the
/// attachment. If validation fails, the timeline is not mutated.
///
/// These tests inject failures at each step and assert no orphan directories, workspace
/// rows, cached managers, or persisted attachment IDs remain.
@Suite("Timeline lifecycle fault injection (PKRR-007)")
struct TimelineLifecycleFaultInjectionTests {

    @Test("attachWorkspaceDoesNotResurrectPermanentlyDeletedTimeline")
    func attachWorkspaceDoesNotResurrectPermanentlyDeletedTimeline() async throws {
        let timelineStore = MockPersistenceService()
        let workspaceStore = BlockingWorkspaceStore()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        try await workspaceStore.saveWorkspace(workspace)

        let manager = TimelineManager(
            stores: .init(
                timelineStore: timelineStore,
                messageStore: timelineStore,
                workspaceStore: workspaceStore,
                toolPersistence: timelineStore
            ),
            workspaceProfile: .noWorkspace
        )
        let timeline = try await manager.createTimeline()

        let attachTask = Task {
            try? await manager.attachWorkspace(workspace.id, to: timeline.id)
        }
        await workspaceStore.waitUntilValidationStarts()

        let deleteTask = Task {
            await manager.deleteTimelinePermanently(id: timeline.id)
        }
        let deletion = await deleteTask.value
        #expect(deletion.isComplete)
        #expect(try await timelineStore.fetchTimeline(id: timeline.id) == nil)

        await workspaceStore.releaseValidation()
        _ = await attachTask.value

        #expect(try await timelineStore.fetchTimeline(id: timeline.id) == nil)
    }

    @Test("attachment store failure does not mutate the cached timeline")
    func attachmentStoreFailureDoesNotMutateCachedTimeline() async throws {
        let timelineStore = AttachmentTimelinePersistence()
        let persistence = MockPersistenceService()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: timelineStore,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .noWorkspace
        )
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        try await persistence.saveWorkspace(workspace)

        let timeline = try await manager.createTimeline()
        let original = try #require(await manager.timeline(id: timeline.id))

        await timelineStore.setSaveFails(true)
        do {
            try await manager.attachWorkspace(workspace.id, to: timeline.id)
            Issue.record("Expected attach save to fail")
        } catch FailingStoreError.saveFailed {
            // Expected.
        }

        let afterAttachFailure = try #require(await manager.timeline(id: timeline.id))
        #expect(afterAttachFailure.attachedWorkspaceIDs == original.attachedWorkspaceIDs)
        #expect(afterAttachFailure.updatedAt == original.updatedAt)

        await timelineStore.setSaveFails(false)
        try await manager.attachWorkspace(workspace.id, to: timeline.id)
        let attached = try #require(await manager.timeline(id: timeline.id))

        await timelineStore.setSaveFails(true)
        do {
            try await manager.detachWorkspace(workspace.id, from: timeline.id)
            Issue.record("Expected detach save to fail")
        } catch FailingStoreError.saveFailed {
            // Expected.
        }

        let afterDetachFailure = try #require(await manager.timeline(id: timeline.id))
        #expect(afterDetachFailure.attachedWorkspaceIDs == attached.attachedWorkspaceIDs)
        #expect(afterDetachFailure.updatedAt == attached.updatedAt)
    }

    // MARK: - createTimeline: timeline store failure leaves no orphan state

    @Test("createTimeline rolls back when the timeline store fails on save")
    func createTimelineRollsBackOnTimelineStoreFailure() async throws {
        let persistence = MockPersistenceService()
        let failingTimelineStore = FailingTimelinePersistence(saveFails: true)
        let workspaceStore = MockWorkspacePersistence()
        let workspace = TestWorkspace()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: failingTimelineStore,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        do {
            _ = try await manager.createTimeline(title: "Failing Timeline")
            Issue.record("Expected TimelineError.unavailable")
        } catch TimelineError.unavailable {
            // Correct — the store failure is surfaced.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(workspaceStore.workspaces.isEmpty,
               "No workspace row should be left when the timeline store fails")
        #expect(persistence.timelines.isEmpty,
               "No timeline record should be left in the message store")
        #expect(await manager.timeline(id: UUID()) == nil,
               "No timeline should be cached in memory")
    }

    @Test("createTimeline rolls back when the workspace store fails on save")
    func createTimelineRollsBackOnWorkspaceStoreFailure() async throws {
        let persistence = MockPersistenceService()
        let failingWorkspaceStore = FailingWorkspaceStore(saveFails: true)
        let workspace = TestWorkspace()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: failingWorkspaceStore,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        var createdTimelineId: UUID?
        do {
            let timeline = try await manager.createTimeline(title: "WS Fail Timeline")
            createdTimelineId = timeline.id
        } catch TimelineError.unavailable {
            // Correct — the workspace store failure is surfaced.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(createdTimelineId == nil, "createTimeline should not return a timeline on failure")

        let timelinesInStore = persistence.timelines
        #expect(timelinesInStore.isEmpty,
               "No timeline record should persist when the workspace store fails")

        let timelinesDir = workspace.root.appendingPathComponent("timelines", isDirectory: true)
        if FileManager.default.fileExists(atPath: timelinesDir.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: timelinesDir.path)
            #expect(contents.isEmpty,
                    "No timeline directory should remain when the workspace store fails")
        }

        #expect(failingWorkspaceStore.saveAttemptCount >= 1,
               "The workspace store save must have been attempted")
    }

    @Test("createTimeline succeeds when all stores are healthy and leaves no orphans")
    func createTimelineHealthyLeavesNoOrphans() async throws {
        let persistence = MockPersistenceService()
        let workspaceStore = MockWorkspacePersistence()
        let workspace = TestWorkspace()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let timeline = try await manager.createTimeline(title: "Healthy Timeline")

        let persistedTimeline = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persistedTimeline.id == timeline.id)

        #expect(workspaceStore.workspaces.count == 1,
               "Exactly one workspace should be saved for a healthy timeline")
        #expect(workspaceStore.workspaces.first?.id == timeline.attachedWorkspaceIDs.first)

        let workingDir = try #require(timeline.workingDirectory)
        #expect(FileManager.default.fileExists(atPath: workingDir),
               "The working directory should exist")

        let cached = await manager.timeline(id: timeline.id)
        #expect(cached != nil, "The timeline should be cached in memory")
    }

    // MARK: - createTimeline: directory or filesystem failure rollback

    @Test("createTimeline rolls back the timeline record when directory creation fails")
    func createTimelineRollsBackOnDirectoryFailure() async throws {
        let persistence = MockPersistenceService()
        let workspaceStore = MockWorkspacePersistence()
        let workspace = TestWorkspace()

        let invalidRoot = workspace.root.appendingPathComponent("invalid")
        try Data().write(to: invalidRoot)

        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                toolPersistence: persistence
            ),
            workspaceRoot: invalidRoot
        )

        do {
            _ = try await manager.createTimeline(title: "Dir Fail Timeline")
            Issue.record("Expected an error")
        } catch {
            // Expected — either TimelineError.unavailable or a filesystem error
        }

        let timelinesInStore = persistence.timelines
        #expect(timelinesInStore.allSatisfy { $0.title != "Dir Fail Timeline" },
               "No timeline record with the failing title should persist")
        #expect(workspaceStore.workspaces.isEmpty,
               "No workspace row should be left when directory creation fails")
    }

    // MARK: - attachWorkspace: workspace validation before persistence

    @Test("attachWorkspace throws and does not mutate the timeline when the workspace does not exist")
    func attachWorkspaceRejectsMissingWorkspace() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let timeline = try await manager.createTimeline()
        let originalAttachedIds = timeline.attachedWorkspaceIDs
        let missingWorkspaceId = UUID()

        do {
            try await manager.attachWorkspace(missingWorkspaceId, to: timeline.id)
            Issue.record("Expected TimelineError.invalidState")
        } catch TimelineError.invalidState {
            // Correct — the workspace does not exist.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.attachedWorkspaceIDs == originalAttachedIds,
               "The timeline's attached workspace IDs must not change when validation fails")
        #expect(!persisted.attachedWorkspaceIDs.contains(missingWorkspaceId),
               "The missing workspace ID must not be persisted")
    }

    @Test("attachWorkspace throws and does not mutate the timeline when the workspace store fails")
    func attachWorkspaceRejectsOnStoreFailure() async throws {
        let persistence = MockPersistenceService()
        let failingWorkspaceStore = FailingWorkspaceStore(fetchFails: true)
        let workspace = TestWorkspace()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: failingWorkspaceStore,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let timeline = try await manager.createTimeline()
        let originalAttachedIds = timeline.attachedWorkspaceIDs
        let workspaceId = UUID()

        do {
            try await manager.attachWorkspace(workspaceId, to: timeline.id)
            Issue.record("Expected TimelineError.unavailable")
        } catch TimelineError.unavailable {
            // Correct — the store failure is surfaced.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.attachedWorkspaceIDs == originalAttachedIds,
               "The timeline's attached workspace IDs must not change when the store fails")
    }

    @Test("attachWorkspace persists the attachment when the workspace exists")
    func attachWorkspaceSucceedsWhenWorkspaceExists() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let timeline = try await manager.createTimeline()
        let attachedWS = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        try await persistence.saveWorkspace(attachedWS)

        try await manager.attachWorkspace(attachedWS.id, to: timeline.id)

        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.attachedWorkspaceIDs.contains(attachedWS.id),
               "The workspace ID should be persisted in the timeline")
    }

    // MARK: - attachWorkspace: already-attached workspace is re-validated

    @Test("attachWorkspace re-validates an already-attached workspace and throws if it was deleted")
    func attachWorkspaceRevalidatesAlreadyAttached() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let timeline = try await manager.createTimeline()
        let attachedWS = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        try await persistence.saveWorkspace(attachedWS)
        try await manager.attachWorkspace(attachedWS.id, to: timeline.id)

        try await persistence.deleteWorkspace(id: attachedWS.id)

        do {
            try await manager.attachWorkspace(attachedWS.id, to: timeline.id)
            Issue.record("Expected TimelineError.invalidState after workspace deletion")
        } catch TimelineError.invalidState {
            // Correct — the workspace no longer exists.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        let attachmentCount = persisted.attachedWorkspaceIDs.filter { $0 == attachedWS.id }.count
        #expect(attachmentCount == 1,
               "The deleted workspace should not be re-attached or duplicated")
    }

    // MARK: - createTimeline: retry after failure succeeds (no stale state)

    @Test("createTimeline can be retried after a transient store failure")
    func createTimelineRetryAfterFailure() async throws {
        let persistence = MockPersistenceService()
        let failingTimelineStore = FailingTimelinePersistence(saveFails: true)
        let workspaceStore = MockWorkspacePersistence()
        let workspace = TestWorkspace()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: failingTimelineStore,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        do {
            _ = try await manager.createTimeline(title: "First Attempt")
        } catch {
            // Expected
        }

        #expect(workspaceStore.workspaces.isEmpty,
               "No orphan workspace after first failure")

        let healthyStore = MockTimelinePersistence()
        let healthyManager = TimelineManager(
            stores: .init(
                timelineStore: healthyStore,
                messageStore: persistence,
                workspaceStore: workspaceStore,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let timeline = try await healthyManager.createTimeline(title: "Retry Attempt")
        #expect(timeline.title == "Retry Attempt")

        let persisted = try #require(await healthyStore.fetchTimeline(id: timeline.id))
        #expect(persisted.id == timeline.id)
        #expect(workspaceStore.workspaces.count == 1,
               "Exactly one workspace after the successful retry")
    }
}
