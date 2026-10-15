import Foundation
import Testing
@testable import PositronicKit
import PKContracts
import PKTestSupport

@Suite("Timeline fork in the same runtime")
struct TimelineForkTests {
    @Test("A fork clones the source session and keeps its own writes isolated")
    func forkClonesSessionAndIsolatesWrites() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "assistant reply"
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Source")
        let context = DirectTurnContext(systemInstructions: "Be concise.")

        let seed = try await timeline.startDirectTurn("hello", context: context)
        _ = await seed.events().collect()
        let sourceBefore = try await kit.timelines.messages(for: timeline.id)
        #expect(sourceBefore.map(\.content) == ["hello", "assistant reply"])

        let fork = try await kit.timelines.fork(from: timeline.id)
        #expect(fork.timelineID != timeline.id)

        // Cloned history matches the source, remapped to the fork's Timeline identity with fresh
        // message IDs.
        let clonedHistory = try await kit.timelines.messages(for: fork.timelineID)
        #expect(clonedHistory.map(\.content) == sourceBefore.map(\.content))
        #expect(clonedHistory.allSatisfy { $0.timelineID == fork.timelineID })
        #expect(Set(clonedHistory.map(\.id)).isDisjoint(with: Set(sourceBefore.map(\.id))))

        // A Turn on the fork appends only to the fork. Direct Turns use only the caller's tools;
        // the read-only set offers no write tool.
        let forkTurn = try await fork.startDirectTurn(
            "do auxiliary work",
            context: context,
            options: TurnOptions(tools: RuntimeToolSets.readOnlyFilesystem(
                root: FileManager.default.temporaryDirectory
            ))
        )
        _ = await forkTurn.events().collect()
        let forkAfter = try await kit.timelines.messages(for: fork.timelineID)
        #expect(forkAfter.map(\.content) == ["hello", "assistant reply", "do auxiliary work", "assistant reply"])

        let forkToolNames = (llm.mockClient.lastTools ?? []).map(\.name)
        #expect(forkToolNames.contains("cat"))
        #expect(forkToolNames.contains("ls"))
        #expect(!forkToolNames.contains { $0.localizedCaseInsensitiveContains("write") })

        // The source Timeline is unchanged.
        let sourceAfter = try await kit.timelines.messages(for: timeline.id)
        #expect(sourceAfter.map(\.content) == sourceBefore.map(\.content))
    }

    @Test("Fork lineage records the source fork point and round-trips through Codable")
    func forkLineageRoundTrips() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let timeline = try await kit.timelines.create(title: "Source")
        let seed = TimelineMessage(timelineID: timeline.id, role: .user, content: "seed")
        try await kit.runtimeRepository.saveMessage(seed)

        let fork = try await kit.timelines.fork(from: timeline.id, title: "Audit")
        let record = try #require(try await kit.timelines.get(fork.timelineID))
        #expect(record.title == "Audit")
        #expect(record.isEphemeral)
        #expect(record.isPrivate)
        #expect(record.attachedAgentID == nil)
        #expect(record.forkedFrom?.timelineID == timeline.id)
        #expect(record.forkedFrom?.throughMessageID == seed.id)

        let cloned = try await kit.timelines.messages(for: fork.timelineID)
        #expect(cloned.count == 1)
        #expect(cloned.first?.id != seed.id)

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TimelineRecord.self, from: data)
        #expect(decoded.isEphemeral)
        #expect(decoded.forkedFrom == record.forkedFrom)

        // A record persisted before the field existed decodes as non-ephemeral.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "isEphemeral")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(TimelineRecord.self, from: legacyData)
        #expect(legacy.isEphemeral == false)
        #expect(legacy.forkedFrom == record.forkedFrom)
    }

    @Test("Ephemeral forks are excluded from listing unless asked")
    func listExcludesEphemeralForks() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let source = try await kit.timelines.create(title: "Source")
        let fork = try await kit.timelines.fork(from: source.id)

        let visible = try await kit.timelines.list()
        #expect(!visible.contains { $0.id == fork.timelineID })

        let all = try await kit.timelines.list(includeEphemeral: true)
        #expect(all.contains { $0.id == fork.timelineID })
    }

    @Test("Releasing the last handle deletes the fork Timeline and its messages")
    func releasingLastHandleDeletesFork() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let source = try await kit.timelines.create(title: "Source")
        var fork: TimelineHandle? = try await kit.timelines.fork(from: source.id)
        let forkID = try #require(fork?.timelineID)
        try await kit.runtimeRepository.saveMessage(
            TimelineMessage(timelineID: forkID, role: .user, content: "fork note")
        )

        fork = nil
        await kit.awaitEphemeralTimelineReleased(forkID)

        #expect(try await kit.timelines.get(forkID) == nil)
        #expect(try await kit.timelines.messages(for: forkID).isEmpty)
        #expect(try await kit.timelines.get(source.id) != nil)
    }

    @Test("A Turn still in flight finishes before its ephemeral Timeline is deleted")
    func inflightTurnFinishesBeforeDeletion() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "assistant reply"
        llm.mockClient.nextStreamWait = 0.1
        let kit = PKRuntime(languageModel: llm)
        let source = try await kit.timelines.create(title: "Source")
        var fork: TimelineHandle? = try await kit.timelines.fork(from: source.id)
        let forkID = try #require(fork?.timelineID)

        let turn = try #require(try await fork?.startDirectTurn(
            "audit",
            context: DirectTurnContext(systemInstructions: "audit")
        ))
        fork = nil

        let events = await turn.events().collect()
        let completed = events.contains { event in
            if case .completion = event { return true }
            return false
        }
        #expect(completed)

        await kit.awaitEphemeralTimelineReleased(forkID)
        #expect(try await kit.timelines.get(forkID) == nil)
    }

    @Test("Forking an unknown Timeline throws")
    func forkingUnknownTimelineThrows() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        await #expect(throws: TimelineError.self) {
            _ = try await kit.timelines.fork(from: UUID())
        }
    }

    @Test("Runtime start purges orphaned ephemeral Timelines")
    func runtimeStartPurgesOrphans() async throws {
        let persistence = MockPersistenceService()
        let orphanID = UUID()
        try await persistence.saveTimeline(TimelineRecord(id: orphanID, isEphemeral: true))
        try await persistence.saveMessage(
            TimelineMessage(timelineID: orphanID, role: .user, content: "orphan")
        )
        let durableID = UUID()
        try await persistence.saveTimeline(TimelineRecord(id: durableID))
        try await persistence.saveMessage(
            TimelineMessage(timelineID: durableID, role: .user, content: "durable")
        )

        let runtime = TestRuntime(
            workspaceRoot: TestRuntime.uniqueWorkspaceRoot(),
            persistence: persistence
        )
        await runtime.runtime.timelineManager.ensureEphemeralSweepStarted()
        await runtime.runtime.timelineManager.awaitEphemeralSweep()

        #expect(try await runtime.timelines.get(orphanID) == nil)
        #expect(try await runtime.timelines.messages(for: orphanID).isEmpty)
        #expect(try await runtime.timelines.get(durableID) != nil)
        #expect(try await runtime.timelines.messages(for: durableID).count == 1)
    }
}
