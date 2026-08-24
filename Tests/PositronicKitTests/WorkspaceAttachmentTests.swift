import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import struct PositronicKit.Thread
import Testing

// MARK: - Test Fixture

/// Sets up a ThreadManager with in-memory persistence and a workspace already seeded.
private struct AttachmentFixture {
    let manager: ThreadManager
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
            manager: ThreadManager(
                stores: .init(
                    threadStore: persistence,
                    messageStore: persistence,
                    workspaceStore: persistence,
                    workspaceBindingRepository: bindingRepository,
                    toolPersistence: persistence
                ),
                workspaceRoot: workspaceRoot
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

private func withFixture(
    _ body: @Sendable (AttachmentFixture) async throws -> Void
) async throws {
    let fixture = try await AttachmentFixture.make()
    try await body(fixture)
}

// MARK: - attachWorkspace

@Suite("ThreadManager.attachWorkspace")
struct AttachWorkspaceTests {
    @Test("attaching creates a repository binding")
    func attach() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
            #expect(workspaces.attached.contains { $0.id == fix.clientWS.id })
        }
    }

    @Test("attaching same workspace twice does not duplicate")
    func noDuplicateAttach() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
            let matching = workspaces.attached.filter { $0.id == fix.clientWS.id }
            #expect(matching.count == 1)
        }
    }

    @Test("multiple distinct workspaces can be attached")
    func multipleAttached() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)
            try await fix.manager.attachWorkspace(fix.extraWS.id, to: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
            #expect(workspaces.attached.contains { $0.id == fix.clientWS.id })
            #expect(workspaces.attached.contains { $0.id == fix.extraWS.id })
            #expect(workspaces.attached.count >= 2)
        }
    }

    @Test("attach persists across a fresh manager reading from DB")
    func attachPersistsToDB() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)

            // New manager, same persistence — simulates runtime restart
            let freshManager = ThreadManager(
                stores: .init(
                    threadStore: fix.persistence,
                    messageStore: fix.persistence,
                    workspaceStore: fix.persistence,
                    workspaceBindingRepository: fix.bindingRepository,
                    toolPersistence: fix.persistence
                ),
                workspaceRoot: fix.workspaceRoot
            )
            let workspaces = try await freshManager.getWorkspaces(for: thread.id)
            #expect(workspaces.attached.contains { $0.id == fix.clientWS.id })
        }
    }

    @Test("attaching to unknown thread throws")
    func unknownThreadThrows() async throws {
        try await withFixture { fix in
            await #expect(throws: (any Error).self) {
                try await fix.manager.attachWorkspace(fix.clientWS.id, to: UUID())
            }
        }
    }

    @Test("attach to a non-cached thread still resolves from persistence")
    func attachUncachedThread() async throws {
        try await withFixture { fix in
            let thread = Thread()
            try await fix.persistence.saveThread(thread)

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)

            let bindings = try await fix.bindingRepository.bindings(for: thread.id)
            #expect(bindings.map(\.workspaceID).contains(fix.clientWS.id))
        }
    }
}

// MARK: - detachWorkspace

@Suite("ThreadManager.detachWorkspace")
struct DetachWorkspaceTests {
    @Test("detaching an attached workspace removes it from the list")
    func detachAttached() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)

            try await fix.manager.detachWorkspace(fix.clientWS.id, from: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
            #expect(!workspaces.attached.contains { $0.id == fix.clientWS.id })
        }
    }

    @Test("detaching workspace not in list does not throw")
    func detachUnknownIsNoOp() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()

            try await fix.manager.detachWorkspace(fix.clientWS.id, from: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
            #expect(workspaces.attached.isEmpty)
        }
    }

    @Test("detaching one workspace leaves others intact")
    func detachLeavesOthers() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)
            try await fix.manager.attachWorkspace(fix.extraWS.id, to: thread.id)

            try await fix.manager.detachWorkspace(fix.clientWS.id, from: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
            #expect(!workspaces.attached.contains { $0.id == fix.clientWS.id })
            #expect(workspaces.attached.contains { $0.id == fix.extraWS.id })
        }
    }

    @Test("detach persists across a fresh manager reading from DB")
    func detachPersistsToDB() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)
            try await fix.manager.detachWorkspace(fix.clientWS.id, from: thread.id)

            let freshManager = ThreadManager(
                stores: .init(
                    threadStore: fix.persistence,
                    messageStore: fix.persistence,
                    workspaceStore: fix.persistence,
                    workspaceBindingRepository: fix.bindingRepository,
                    toolPersistence: fix.persistence
                ),
                workspaceRoot: fix.workspaceRoot
            )
            let workspaces = try await freshManager.getWorkspaces(for: thread.id)
            #expect(!workspaces.attached.contains { $0.id == fix.clientWS.id })
        }
    }

    @Test("legacy Thread workspace data is not imported during lookup")
    func legacyProjectionIsNotImported() async throws {
        try await withFixture { fix in
            let legacyThreadID = UUID()
            let legacyObject: [String: Any] = [
                "id": legacyThreadID.uuidString,
                "title": "Legacy thread",
                "createdAt": "2026-08-24T00:00:00Z",
                "updatedAt": "2026-08-24T00:00:00Z",
                "isArchived": false,
                "attachedWorkspaceIds": "[\"\(fix.clientWS.id.uuidString)\"]",
                "isPrivate": false,
            ]
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
            let legacyThread = try decoder.decode(Thread.self, from: legacyData)
            try await fix.persistence.saveThread(legacyThread)

            let workspaces = try await fix.manager.getWorkspaces(for: legacyThreadID)

            #expect(workspaces.primary == nil)
            #expect(workspaces.attached.isEmpty)
            #expect(try await fix.bindingRepository.bindings(for: legacyThreadID).isEmpty)
        }
    }

    @Test("detaching from unknown thread throws")
    func unknownThreadThrows() async throws {
        try await withFixture { fix in
            await #expect(throws: (any Error).self) {
                try await fix.manager.detachWorkspace(fix.clientWS.id, from: UUID())
            }
        }
    }
}

// MARK: - getWorkspaces

@Suite("ThreadManager.getWorkspaces", .serialized)
struct GetWorkspacesTests {
    @Test("throws threadNotFound for unknown thread")
    func throwsForUnknown() async throws {
        try await withFixture { fix in
            await #expect(throws: ThreadError.threadNotFound) {
                _ = try await fix.manager.getWorkspaces(for: UUID())
            }
        }
    }

    @Test("returns empty attached when nothing is attached")
    func emptyAfterCreate() async throws {
        try await withFixture { fix in
            let thread = Thread()
            try await fix.persistence.saveThread(thread)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
            #expect(workspaces.primary == nil)
            #expect(workspaces.attached.isEmpty)
        }
    }

    @Test("createThread exposes its runtime workspace as primary")
    func createThreadPrimaryWorkspace() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)

            #expect(workspaces.primary != nil)
            #expect(workspaces.primary?.location == .runtime)
            #expect(workspaces.attached.isEmpty)
        }
    }

    @Test("canonical runtimeThread workspace is exposed as primary")
    func canonicalRuntimeThreadWorkspaceIsPrimary() async throws {
        try await withFixture { fix in
            let thread = Thread()
            let canonicalWorkspace = WorkspaceReference(
                uri: .threadWorkspace(thread.id),
                location: .runtimeThread
            )
            try await fix.persistence.saveWorkspace(canonicalWorkspace)
            _ = try await fix.bindingRepository.claim(
                workspaceID: canonicalWorkspace.id,
                for: thread.id
            )
            try await fix.persistence.saveThread(thread)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)

            #expect(workspaces.primary?.id == canonicalWorkspace.id)
            #expect(workspaces.attached.isEmpty)
        }
    }

    @Test("reflects attach then detach in sequence")
    func attachThenDetach() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)
            let afterAttach = try await fix.manager.getWorkspaces(for: thread.id)
            #expect(afterAttach.attached.contains { $0.id == fix.clientWS.id } == true)

            try await fix.manager.detachWorkspace(fix.clientWS.id, from: thread.id)
            let afterDetach = try await fix.manager.getWorkspaces(for: thread.id)
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

            let thread = try await fix.manager.createThread()
            try await fix.manager.attachWorkspace(missingWS.id, to: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
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

            let thread = try await fix.manager.createThread()
            try await fix.manager.attachWorkspace(clientWithPath.id, to: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
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

            let thread = try await fix.manager.createThread()
            try await fix.manager.attachWorkspace(ws.id, to: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
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

            let thread = try await fix.manager.createThread()
            try await fix.manager.attachWorkspace(wsNoPath.id, to: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
            let found = workspaces.attached.first { $0.id == wsNoPath.id }
            #expect(found?.status != .missing)
        }
    }
}

// MARK: - Attach/Detach round-trip

@Suite("Workspace attach/detach round-trip")
struct WorkspaceRoundTripTests {
    @Test("detaching all extra workspaces removes them from attached list")
    func detachAll() async throws {
        try await withFixture { fix in
            let thread = try await fix.manager.createThread()
            try await fix.manager.attachWorkspace(fix.runtimeWS.id, to: thread.id)
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)
            try await fix.manager.attachWorkspace(fix.extraWS.id, to: thread.id)

            try await fix.manager.detachWorkspace(fix.runtimeWS.id, from: thread.id)
            try await fix.manager.detachWorkspace(fix.clientWS.id, from: thread.id)
            try await fix.manager.detachWorkspace(fix.extraWS.id, from: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
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
            let thread = try await fix.manager.createThread()

            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)
            try await fix.manager.detachWorkspace(fix.clientWS.id, from: thread.id)
            try await fix.manager.attachWorkspace(fix.clientWS.id, to: thread.id)

            let workspaces = try await fix.manager.getWorkspaces(for: thread.id)
            #expect(workspaces.attached.contains { $0.id == fix.clientWS.id } == true)
        }
    }
}
