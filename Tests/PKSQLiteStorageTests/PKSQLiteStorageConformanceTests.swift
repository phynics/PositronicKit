import Foundation
import PKContracts
import PKSQLiteStorage
import PKTestSupport
import PositronicKit
import Testing

// Each test runs against an isolated database. The file-backed tests create their own
// temporary directory so nothing is shared between scenarios or test runs.
@Suite("PKSQLiteStorage conformance", .serialized)
struct PKSQLiteStorageConformanceTests {
    // MARK: Timeline runtime repository

    @Test("TimelineRuntimeRepository conformance (in-memory)")
    func timelineConformanceInMemory() async throws {
        try await TimelineRuntimeRepositoryConformanceSuite.run {
            try await PKSQLiteStorage.inMemory().persistenceConfiguration.runtimeRepository
        }
    }

    @Test("TimelineRuntimeRepository conformance (file)")
    func timelineConformanceFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await TimelineRuntimeRepositoryConformanceSuite.run {
            let storage = try await PKSQLiteStorage.open(
                at: root.appendingPathComponent("\(UUID().uuidString).sqlite")
            )
            return storage.persistenceConfiguration.runtimeRepository
        }
    }

    // MARK: Focused stores

    @Test("WorkspaceStore conformance (file)")
    func workspaceConformanceFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await WorkspaceStoreConformanceSuite.run {
            try await PKSQLiteStorage.open(
                at: root.appendingPathComponent("\(UUID().uuidString).sqlite")
            ).persistenceConfiguration.workspacePersistence
        }
    }

    @Test("AgentStoreProtocol conformance (file)")
    func agentConformanceFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await AgentStoreConformanceSuite.run {
            try await PKSQLiteStorage.open(
                at: root.appendingPathComponent("\(UUID().uuidString).sqlite")
            ).persistenceConfiguration.agentStore
        }
    }

    @Test("RequestOriginStoreProtocol conformance (file)")
    func requestOriginConformanceFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await RequestOriginStoreConformanceSuite.run {
            try await PKSQLiteStorage.open(
                at: root.appendingPathComponent("\(UUID().uuidString).sqlite")
            ).persistenceConfiguration.requestOriginStore
        }
    }

    // MARK: Durability

    @Test("a file-backed configuration reports every store durable")
    func fileStorageIsFullyDurable() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try await PKSQLiteStorage.open(at: root.appendingPathComponent("durable.sqlite"))
        let report = storage.persistenceConfiguration.validateDurability()
        #expect(storage.isDurable)
        #expect(!report.isMixed)
        #expect(report.ephemeralStores.isEmpty)
        #expect(report.stores.count == 5)
        try await storage.close()
    }

    @Test("an in-memory configuration reports every store ephemeral")
    func inMemoryStorageIsEphemeral() async throws {
        let storage = try await PKSQLiteStorage.inMemory()
        let report = storage.persistenceConfiguration.validateDurability()
        #expect(!storage.isDurable)
        #expect(!report.isMixed)
        #expect(report.ephemeralStores.count == 5)
    }

    // MARK: Durability across reopen

    @Test("committed state survives close and reopen")
    func stateSurvivesReopen() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("positronic.sqlite")
        let timelineID = UUID()
        let messageID = UUID()

        do {
            let storage = try await PKSQLiteStorage.open(at: url)
            let repository = storage.persistenceConfiguration.runtimeRepository
            try await repository.saveTimeline(TimelineRecord(id: timelineID, title: "Kept"))
            try await repository.saveMessage(
                TimelineMessage(id: messageID, timelineID: timelineID, role: .user, content: "persist me")
            )
            try await storage.close()
        }

        let reopened = try await PKSQLiteStorage.open(at: url)
        let repository = reopened.persistenceConfiguration.runtimeRepository
        let timeline = try #require(try await repository.fetchTimeline(id: timelineID))
        #expect(timeline.title == "Kept")
        #expect(try await repository.fetchMessages(for: timelineID).map(\.id) == [messageID])
        try await reopened.close()
    }

    @Test("an admitted active Turn is visible after reopen")
    func activeTurnSurvivesReopen() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("positronic.sqlite")
        let timelineID = UUID()
        let requestID = UUID()
        let input = TimelineMessage(id: requestID, timelineID: timelineID, role: .user, content: "go")

        let admitted: TurnAdmission
        do {
            let storage = try await PKSQLiteStorage.open(at: url)
            let repository = storage.persistenceConfiguration.runtimeRepository
            try await repository.saveTimeline(TimelineRecord(id: timelineID))
            admitted = try await repository.admitTurn(
                timelineID: timelineID,
                requestID: requestID,
                callerIntentFingerprint: "go",
                inputMessage: input,
                now: Date(timeIntervalSince1970: 1)
            )
            try await storage.close()
        }

        let reopened = try await PKSQLiteStorage.open(at: url)
        let repository = reopened.persistenceConfiguration.runtimeRepository
        let active = try #require(try await repository.fetchActiveTurn(for: timelineID))
        #expect(active.identity.turnID == admitted.turn.identity.turnID)
        #expect(try await repository.fetchTurnMessages(turnID: active.identity.turnID)?.map(\.id) == [input.id])
        try await reopened.close()
    }

    // MARK: Workspace bindings

    @Test("workspace bindings enforce the single-owner rule")
    func workspaceBindings() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try await PKSQLiteStorage.open(at: root.appendingPathComponent("bindings.sqlite"))
        let bindings = storage.persistenceConfiguration.workspaceBindingRepository
        let workspaceID = UUID()
        let timelineID = UUID()

        let binding = try await bindings.claim(workspaceID: workspaceID, for: timelineID, now: Date())
        #expect(binding.timelineID == timelineID)
        #expect(try await bindings.timelineID(for: workspaceID) == timelineID)
        #expect(try await bindings.bindings(for: timelineID).map(\.workspaceID) == [workspaceID])

        await #expect(throws: WorkspaceBindingRepositoryError.self) {
            try await bindings.claim(workspaceID: workspaceID, for: UUID(), now: Date())
        }
        try await storage.close()
    }
}

// MARK: - Helpers

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pk-sqlite-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
