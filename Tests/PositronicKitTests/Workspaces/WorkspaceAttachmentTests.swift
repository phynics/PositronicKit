import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

// MARK: - Test Fixture

/// Sets up a TimelineManager with in-memory persistence and a workspace already seeded.
private struct AttachmentFixture {
    let manager: TimelineManager
    let persistence: MockPersistenceService
    let bindingRepository: InMemoryWorkspaceBindingRepository
    let workspaceRoot: URL

    /// Saved workspace references — pre-seeded into persistence before tests run.
    let runtimeWS: WorkspaceReference
    let clientWS: WorkspaceReference
    let extraWS: WorkspaceReference

    static func make() async throws -> Self {
        let persistence = MockPersistenceService()
        let bindingRepository = InMemoryWorkspaceBindingRepository()
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)

        let runtimeWS = WorkspaceReference(
            uri: WorkspaceURI(host: "pk-runtime", path: "/agent/primary"),
            location: .runtime,
            rootPath: workspaceRoot.appendingPathComponent("primary").path
        )
        let clientWS = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        let extraWS = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/lib"),
            location: .attached
        )

        try await persistence.saveWorkspace(runtimeWS)
        try await persistence.saveWorkspace(clientWS)
        try await persistence.saveWorkspace(extraWS)

        return Self(
            manager: TimelineManager(
                stores: .init(
                    timelineStore: persistence,
                    messageStore: persistence,
                    workspaceStore: persistence,
                    workspaceBindingRepository: bindingRepository,
                    runtimeRepository: persistence,
                    toolPersistence: persistence
                ),
                workspaceProfile: .hostManaged(root: workspaceRoot)
            ),
            persistence: persistence,
            bindingRepository: bindingRepository,
            workspaceRoot: workspaceRoot,
            runtimeWS: runtimeWS,
            clientWS: clientWS,
            extraWS: extraWS
        )
    }
}

/// A gate that pauses the first persistence read after it obtains its snapshot. This makes the
/// stale-snapshot window deterministic without relying on timing or sleeps.
private actor TimelineFetchGate {
    private var entered = false
    private var released = false
    private var shouldPause = true

    func pauseFirstFetch() async {
        guard shouldPause else { return }
        shouldPause = false
        entered = true
        while !released {
            await Task.yield()
        }
    }

    func hasEntered() -> Bool { entered }
    func release() { released = true }
}

private struct GatedTimelineStore: TimelinePersistenceProtocol {
    let base: any TimelinePersistenceProtocol
    let gate: TimelineFetchGate

    func saveTimeline(_ timeline: TimelineRecord) async throws { try await base.saveTimeline(timeline) }

    func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        let snapshot = try await base.fetchTimeline(id: id)
        await gate.pauseFirstFetch()
        return snapshot
    }

    func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord] {
        try await base.fetchAllTimelines(includeArchived: includeArchived)
    }

    func deleteTimeline(id: UUID) async throws { try await base.deleteTimeline(id: id) }

    func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await base.pruneTimelines(
            olderThan: timeInterval,
            excluding: excludedTimelineIDs,
            dryRun: dryRun
        )
    }
}

private func makeGatedManager(
    fixture: AttachmentFixture,
    timelineStore: any TimelinePersistenceProtocol
) -> TimelineManager {
    let resolver = WorkspaceResolverFactory.makeDefault(
        workspaceRoot: fixture.workspaceRoot,
        workspaceStore: fixture.persistence,
        bindingRepository: fixture.bindingRepository
    )
    return TimelineManager(
        stores: .init(
            timelineStore: timelineStore,
            messageStore: fixture.persistence,
            workspaceStore: fixture.persistence,
            workspaceBindingRepository: fixture.bindingRepository,
            runtimeRepository: fixture.persistence,
            toolPersistence: fixture.persistence
        ),
        workspaceProfile: .hostManaged(root: fixture.workspaceRoot),
        resolver: resolver
    )
}

private func withFixture(
    _ body: @Sendable (AttachmentFixture) async throws -> Void
) async throws {
    let fixture = try await AttachmentFixture.make()
    try await body(fixture)
}

// MARK: - attachWorkspace

@Suite("TimelineManager.attachWorkspace", .tags(.integration))
struct AttachWorkspaceTests {
    @Test("attaching creates a repository binding")
    func attach() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(workspaces.attached.contains { $0.id == fix.clientWS.id })
        }
    }

    @Test("attaching same workspace twice does not duplicate")
    func noDuplicateAttach() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            let matching = workspaces.attached.filter { $0.id == fix.clientWS.id }
            #expect(matching.count == 1)
        }
    }

    @Test("multiple distinct workspaces can be attached")
    func multipleAttached() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)
            try await fix.manager.attachWorkspace(fix.extraWS.id, to: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(workspaces.attached.contains { $0.id == fix.clientWS.id })
            #expect(workspaces.attached.contains { $0.id == fix.extraWS.id })
            #expect(workspaces.attached.count >= 2)
        }
    }

    @Test("attach persists across a fresh manager reading from DB")
    func attachPersistsToDB() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)

            // New manager, same persistence — simulates runtime restart
            let freshManager = TimelineManager(
                stores: .init(
                    timelineStore: fix.persistence,
                    messageStore: fix.persistence,
                    workspaceStore: fix.persistence,
                    workspaceBindingRepository: fix.bindingRepository,
                    runtimeRepository: fix.persistence,
                    toolPersistence: fix.persistence
                ),
                workspaceProfile: .hostManaged(root: fix.workspaceRoot)
            )
            let workspaces = try await freshManager.getWorkspaces(for: timeline.id)
            #expect(workspaces.attached.contains { $0.id == fix.clientWS.id })
        }
    }

    @Test("attaching to unknown timeline throws")
    func unknownTimelineThrows() async throws {
        try await withFixture { fix in
            await #expect(throws: (any Error).self) {
                try await fix.manager.attachWorkspace(fix.clientWS.id, to: UUID())
            }
        }
    }

    @Test("attach to a non-cached timeline still resolves from persistence")
    func attachUncachedTimeline() async throws {
        try await withFixture { fix in
            let timeline = TimelineRecord()
            try await fix.persistence.saveTimeline(timeline)

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)

            let bindings = try await fix.bindingRepository.bindings(for: timeline.id)
            #expect(bindings.map(\.workspaceID).contains(fix.clientWS.id))
        }
    }

    @Test("attach preserves metadata committed during its authoritative refresh")
    func attachPreservesConcurrentMetadata() async throws {
        let fix = try await AttachmentFixture.make()
        let timeline = TimelineRecord()
        try await fix.persistence.saveTimeline(timeline)

        let gate = TimelineFetchGate()
        let manager = makeGatedManager(
            fixture: fix,
            timelineStore: GatedTimelineStore(base: fix.persistence, gate: gate)
        )
        let attachTask = Task {
            try await manager.attachWorkspace(fix.clientWS.id, to: timeline.id)
        }

        while !(await gate.hasEntered()) { await Task.yield() }
        var renamed = try #require(await fix.persistence.fetchTimeline(id: timeline.id))
        renamed.title = "renamed while attaching"
        try await fix.persistence.saveTimeline(renamed)
        await gate.release()
        try await attachTask.value

        let persisted = try #require(await fix.persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.title == "renamed while attaching")
    }
}

// MARK: - detachWorkspace

@Suite("TimelineManager.detachWorkspace", .tags(.integration))
struct DetachWorkspaceTests {
    @Test("detaching an attached workspace removes it from the list")
    func detachAttached() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)

            try await fix.manager.detachWorkspace(fix.clientWS.id, from: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(!workspaces.attached.contains { $0.id == fix.clientWS.id })
        }
    }

    @Test("detach preserves metadata committed during its authoritative refresh")
    func detachPreservesConcurrentMetadata() async throws {
        let fix = try await AttachmentFixture.make()
        let timeline = TimelineRecord()
        try await fix.persistence.saveTimeline(timeline)
        _ = try await fix.bindingRepository.claim(
            workspaceID: fix.clientWS.id,
            for: timeline.id
        )

        let gate = TimelineFetchGate()
        let manager = makeGatedManager(
            fixture: fix,
            timelineStore: GatedTimelineStore(base: fix.persistence, gate: gate)
        )
        let detachTask = Task {
            try await manager.detachWorkspace(fix.clientWS.id, from: timeline.id)
        }

        while !(await gate.hasEntered()) { await Task.yield() }
        var renamed = try #require(await fix.persistence.fetchTimeline(id: timeline.id))
        renamed.title = "renamed while detaching"
        try await fix.persistence.saveTimeline(renamed)
        await gate.release()
        try await detachTask.value

        let persisted = try #require(await fix.persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.title == "renamed while detaching")
    }

    @Test("detaching workspace not in list does not throw")
    func detachUnknownIsNoOp() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()

            try await fix.manager.detachWorkspace(fix.clientWS.id, from: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(workspaces.attached.isEmpty)
        }
    }

    @Test("detaching one workspace leaves others intact")
    func detachLeavesOthers() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)
            try await fix.manager.attachWorkspace(fix.extraWS.id, to: timeline.id)

            try await fix.manager.detachWorkspace(fix.clientWS.id, from: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(!workspaces.attached.contains { $0.id == fix.clientWS.id })
            #expect(workspaces.attached.contains { $0.id == fix.extraWS.id })
        }
    }

    @Test("detach persists across a fresh manager reading from DB")
    func detachPersistsToDB() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)
            try await fix.manager.detachWorkspace(fix.clientWS.id, from: timeline.id)

            let freshManager = TimelineManager(
                stores: .init(
                    timelineStore: fix.persistence,
                    messageStore: fix.persistence,
                    workspaceStore: fix.persistence,
                    workspaceBindingRepository: fix.bindingRepository,
                    runtimeRepository: fix.persistence,
                    toolPersistence: fix.persistence
                ),
                workspaceProfile: .hostManaged(root: fix.workspaceRoot)
            )
            let workspaces = try await freshManager.getWorkspaces(for: timeline.id)
            #expect(!workspaces.attached.contains { $0.id == fix.clientWS.id })
        }
    }

    @Test("legacy Timeline workspace data is not imported during lookup")
    func legacyProjectionIsNotImported() async throws {
        try await withFixture { fix in
            let legacyTimelineID = UUID()
            let legacyObject: [String: Any] = [
                "id": legacyTimelineID.uuidString,
                "title": "Legacy timeline",
                "createdAt": "2026-08-24T00:00:00Z",
                "updatedAt": "2026-08-24T00:00:00Z",
                "isArchived": false,
                "attachedWorkspaceIds": "[\"\(fix.clientWS.id.uuidString)\"]",
                "isPrivate": false,
            ]
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
            let legacyTimeline = try decoder.decode(TimelineRecord.self, from: legacyData)
            try await fix.persistence.saveTimeline(legacyTimeline)

            let workspaces = try await fix.manager.getWorkspaces(for: legacyTimelineID)

            #expect(workspaces.primary == nil)
            #expect(workspaces.attached.isEmpty)
            #expect(try await fix.bindingRepository.bindings(for: legacyTimelineID).isEmpty)
        }
    }

    @Test("detaching from unknown timeline throws")
    func unknownTimelineThrows() async throws {
        try await withFixture { fix in
            await #expect(throws: (any Error).self) {
                try await fix.manager.detachWorkspace(fix.clientWS.id, from: UUID())
            }
        }
    }
}

// MARK: - getWorkspaces

// `.serialized`: attachment scenarios seed workspaces under one shared test-root parent.
// Serialization avoids temporary-directory churn between the scenarios (issue #155).
@Suite("TimelineManager.getWorkspaces", .serialized, .tags(.integration))
struct GetWorkspacesTests {
    @Test("throws timelineNotFound for unknown timeline")
    func throwsForUnknown() async throws {
        try await withFixture { fix in
            await #expect(throws: TimelineError.timelineNotFound) {
                _ = try await fix.manager.getWorkspaces(for: UUID())
            }
        }
    }

    @Test("returns empty attached when nothing is attached")
    func emptyAfterCreate() async throws {
        try await withFixture { fix in
            let timeline = TimelineRecord()
            try await fix.persistence.saveTimeline(timeline)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(workspaces.primary == nil)
            #expect(workspaces.attached.isEmpty)
        }
    }

    @Test("createTimeline exposes its runtime workspace as primary")
    func createTimelinePrimaryWorkspace() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)

            #expect(workspaces.primary != nil)
            #expect(workspaces.primary?.location == .runtime)
            #expect(workspaces.attached.isEmpty)
        }
    }

    @Test("canonical runtimeTimeline workspace is exposed as primary")
    func canonicalRuntimeTimelineWorkspaceIsPrimary() async throws {
        try await withFixture { fix in
            let timeline = TimelineRecord()
            let canonicalWorkspace = WorkspaceReference(
                uri: .timelineWorkspace(timeline.id),
                location: .runtimeTimeline
            )
            try await fix.persistence.saveWorkspace(canonicalWorkspace)
            _ = try await fix.bindingRepository.claim(
                workspaceID: canonicalWorkspace.id,
                for: timeline.id
            )
            try await fix.persistence.saveTimeline(timeline)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)

            #expect(workspaces.primary?.id == canonicalWorkspace.id)
            #expect(workspaces.attached.isEmpty)
        }
    }

    @Test("reflects attach then detach in sequence")
    func attachThenDetach() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)
            let afterAttach = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(afterAttach.attached.contains { $0.id == fix.clientWS.id } == true)

            try await fix.manager.detachWorkspace(fix.clientWS.id, from: timeline.id)
            let afterDetach = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(afterDetach.attached.contains { $0.id == fix.clientWS.id } == false)
        }
    }

    @Test("runtime workspace with missing rootPath is marked .missing")
    func serverMissingPath() async throws {
        try await withFixture { fix in
            let missingWS = WorkspaceReference(
                uri: WorkspaceURI(host: "pk-runtime", path: "/agent/gone"),
                location: .runtime,
                rootPath: "/tmp/pk-test-definitely-does-not-exist-\(UUID().uuidString)"
            )
            try await fix.persistence.saveWorkspace(missingWS)

            let timeline = try await fix.manager.createTimeline()
            try await fix.manager.attachWorkspace(missingWS.id, to: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            let ws = workspaces.attached.first { $0.id == missingWS.id }
            #expect(ws?.status == .missing)
        }
    }

    @Test("attached workspace with missing rootPath is NOT marked .missing")
    func clientMissingPathIgnored() async throws {
        try await withFixture { fix in
            let clientWithPath = WorkspaceReference(
                uri: WorkspaceURI(host: "user-mac", path: "/projects/gone"),
                location: .attached,
                rootPath: "/tmp/pk-test-definitely-does-not-exist-\(UUID().uuidString)"
            )
            try await fix.persistence.saveWorkspace(clientWithPath)

            let timeline = try await fix.manager.createTimeline()
            try await fix.manager.attachWorkspace(clientWithPath.id, to: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            let ws = workspaces.attached.first { $0.id == clientWithPath.id }
            #expect(ws?.status != .missing, "Attached workspace paths are not validated runtime")
        }
    }

    @Test("runtime workspace with existing path stays .active")
    func serverExistingPathActive() async throws {
        try await withFixture { fix in
            let existingDir = fix.workspaceRoot.appendingPathComponent("present-ws")
            try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)

            let ws = WorkspaceReference(
                uri: WorkspaceURI(host: "pk-runtime", path: "/agent/present"),
                location: .runtime,
                rootPath: existingDir.path
            )
            try await fix.persistence.saveWorkspace(ws)

            let timeline = try await fix.manager.createTimeline()
            try await fix.manager.attachWorkspace(ws.id, to: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            let found = workspaces.attached.first { $0.id == ws.id }
            #expect(found?.status == .active)
        }
    }

    @Test("workspace with nil rootPath is not marked missing regardless of location")
    func nilRootPathNotMissing() async throws {
        try await withFixture { fix in
            let wsNoPath = WorkspaceReference(
                uri: WorkspaceURI(host: "pk-runtime", path: "/agent/no-path"),
                location: .runtime,
                rootPath: nil
            )
            try await fix.persistence.saveWorkspace(wsNoPath)

            let timeline = try await fix.manager.createTimeline()
            try await fix.manager.attachWorkspace(wsNoPath.id, to: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            let found = workspaces.attached.first { $0.id == wsNoPath.id }
            #expect(found?.status != .missing)
        }
    }
}

// MARK: - Attach/Detach round-trip

@Suite("Workspace attach/detach round-trip", .tags(.integration))
struct WorkspaceRoundTripTests {
    @Test("detaching all extra workspaces removes them from attached list")
    func detachAll() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()
            try await fix.manager.attachWorkspace(fix.runtimeWS.id, to: timeline.id)
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)
            try await fix.manager.attachWorkspace(fix.extraWS.id, to: timeline.id)

            try await fix.manager.detachWorkspace(fix.runtimeWS.id, from: timeline.id)
            try await fix.manager.detachWorkspace(fix.clientWS.id, from: timeline.id)
            try await fix.manager.detachWorkspace(fix.extraWS.id, from: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(workspaces.primary?.location == .runtime)
            let attached = workspaces.attached
            #expect(!attached.contains { $0.id == fix.runtimeWS.id })
            #expect(!attached.contains { $0.id == fix.clientWS.id })
            #expect(!attached.contains { $0.id == fix.extraWS.id })
        }
    }

    @Test("re-attaching a previously detached workspace works")
    func reattach() async throws {
        try await withFixture { fix in
            let timeline = try await fix.manager.createTimeline()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)
            try await fix.manager.detachWorkspace(fix.clientWS.id, from: timeline.id)
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: timeline.id)

            let workspaces = try await fix.manager.getWorkspaces(for: timeline.id)
            #expect(workspaces.attached.contains { $0.id == fix.clientWS.id } == true)
        }
    }
}
