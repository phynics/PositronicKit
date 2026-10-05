import Foundation
import Testing
@testable import PositronicKit
import PKContracts
import PKTestSupport

@Suite("Timeline session fork")
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

        let fork = try await kit.fork(from: timeline.id, context: context)
        #expect(fork.timelineID != timeline.id)

        // Cloned history matches the source, remapped to the fork's Timeline identity.
        let clonedHistory = try await fork.messages()
        #expect(clonedHistory.map(\.content) == sourceBefore.map(\.content))
        #expect(clonedHistory.allSatisfy { $0.timelineID == fork.timelineID })

        // A Turn on the fork appends only to the fork.
        let forkTurn = try await fork.startTurn("do auxiliary work")
        _ = await forkTurn.events().collect()
        let forkAfter = try await fork.messages()
        #expect(forkAfter.map(\.content) == ["hello", "assistant reply", "do auxiliary work", "assistant reply"])

        // Fork Turns offer the read-only tool set: filesystem reads and Timeline observation, but
        // never the Timeline-send tool or a file-writing tool.
        let forkToolNames = (llm.mockClient.lastTools ?? []).map(\.name)
        #expect(forkToolNames.contains("cat"))
        #expect(forkToolNames.contains("thread_list"))
        #expect(!forkToolNames.contains("thread_send"))
        #expect(!forkToolNames.contains { $0.localizedCaseInsensitiveContains("write") })

        // The source Timeline is unchanged.
        let sourceAfter = try await kit.timelines.messages(for: timeline.id)
        #expect(sourceAfter.map(\.content) == sourceBefore.map(\.content))
    }

    @Test("A fork is released when its handle is released")
    func forkReleasesOnDeinit() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let timeline = try await kit.timelines.create(title: "Source")
        var fork: TimelineFork? = try await kit.fork(
            from: timeline.id,
            context: DirectTurnContext(systemInstructions: "")
        )
        weak let weakFork = fork
        fork = nil
        #expect(weakFork == nil)
    }

    @Test("Forking an unknown Timeline throws")
    func forkingUnknownTimelineThrows() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        await #expect(throws: TimelineError.self) {
            _ = try await kit.fork(
                from: UUID(),
                context: DirectTurnContext(systemInstructions: "")
            )
        }
    }
}
