import Foundation
import PKContracts
import PKTestSupport
@_spi(Experimental) @testable import PositronicKit
import Testing

/// End-to-end coverage for #281: a host can issue a cache-exact sibling request over a Timeline's
/// retained final-round prefix without writing to the Timeline.
@Suite("Timeline sibling requests", .serialized, .timeLimit(.minutes(2)), .tags(.integration))
struct TimelineSiblingRequestTests {
    private func makeRuntime(
        retainsSiblingPrefix: Bool = true
    ) -> TestRuntime {
        let root = TestRuntime.uniqueWorkspaceRoot()
        return TestRuntime(
            workspaceRoot: root,
            runtime: PKRuntime.RuntimeConfiguration(
                workspaceProfile: .hostManaged(root: root),
                workspaceCreator: MockWorkspaceCreator(),
                retainsSiblingPrefix: retainsSiblingPrefix
            )
        )
    }

    private func makeTimeline(in runtime: TestRuntime) async throws -> (TimelineHandle, Agent) {
        let agent = try await runtime.agents.create(name: "Sibling Agent", description: "test")
        let timeline = try await runtime.timelines.create(title: "Sibling", attaching: agent.id)
        return (timeline, agent)
    }

    @Test("sibling request replays the retained prefix and preserves the Timeline")
    func siblingRequestReplaysRetainedPrefix() async throws {
        let runtime = makeRuntime()
        let (timeline, _) = try await makeTimeline(in: runtime)

        runtime.llm.mockClient.nextResponse = "first answer"
        let first = try await timeline.startTurn("first question")
        for await _ in first.events() {}
        #expect(try await first.outcome() == .completed)

        let sourceCapture = try #require(runtime.llm.generationCaptureHistory.last)
        #expect(sourceCapture.promptCache != nil)

        let transcriptBefore = try await runtime.repository.fetchMessages(for: timeline.timelineID)

        runtime.llm.mockClient.nextResponse = "critique"
        let appended = LLMMessage(role: .user, content: "critique this answer")
        let response = try await timeline.siblingRequest(appending: [appended])

        let siblingCapture = try #require(runtime.llm.completionCaptureHistory.last)
        #expect(siblingCapture.messages == sourceCapture.messages + [appended])
        #expect(Self.toolBytes(siblingCapture.tools) == Self.toolBytes(sourceCapture.tools))
        #expect(siblingCapture.promptCache == sourceCapture.promptCache)
        #expect(response.content == "critique")

        let transcriptAfter = try await runtime.repository.fetchMessages(for: timeline.timelineID)
        #expect(transcriptAfter.map(\.id) == transcriptBefore.map(\.id))
    }

    @Test("sibling request stream replays the retained prefix")
    func siblingRequestStreamReplaysRetainedPrefix() async throws {
        let runtime = makeRuntime()
        let (timeline, _) = try await makeTimeline(in: runtime)

        runtime.llm.mockClient.nextResponse = "first answer"
        let first = try await timeline.startTurn("first question")
        for await _ in first.events() {}
        #expect(try await first.outcome() == .completed)

        let sourceCapture = try #require(runtime.llm.generationCaptureHistory.last)

        runtime.llm.mockClient.nextResponse = "streamed"
        let appended = LLMMessage(role: .user, content: "stream this")
        let stream = try await timeline.siblingRequestStream(appending: [appended])
        var content = ""
        for try await chunk in stream {
            content += chunk.choices.first?.delta.content ?? ""
        }

        let siblingCapture = try #require(runtime.llm.generationCaptureHistory.last)
        #expect(siblingCapture.messages == sourceCapture.messages + [appended])
        #expect(Self.toolBytes(siblingCapture.tools) == Self.toolBytes(sourceCapture.tools))
        #expect(siblingCapture.promptCache == sourceCapture.promptCache)
        #expect(content == "streamed")
    }

    /// Encodes a tool catalog deterministically so two catalogs can be compared without
    /// `LLMToolDefinition` being `Equatable`.
    private static func toolBytes(_ tools: [LLMToolDefinition]?) -> Data? {
        guard let tools else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(tools)
    }

    @Test("no retained round is a structured error")
    func noRetainedRound() async throws {
        let runtime = makeRuntime()
        let (timeline, _) = try await makeTimeline(in: runtime)

        await #expect(throws: TimelineError.siblingPrefixUnavailable(.noRetainedRound)) {
            try await timeline.siblingRequest(appending: [LLMMessage(role: .user, content: "x")])
        }
    }

    @Test("retention disabled is a structured error")
    func retentionDisabled() async throws {
        let runtime = makeRuntime(retainsSiblingPrefix: false)
        let (timeline, _) = try await makeTimeline(in: runtime)

        await #expect(throws: TimelineError.siblingPrefixUnavailable(.retentionDisabled)) {
            try await timeline.siblingRequest(appending: [LLMMessage(role: .user, content: "x")])
        }
    }

    @Test("absent Timeline is a structured error")
    func absentTimeline() async throws {
        let runtime = makeRuntime()
        let handle = runtime.timelines.open(UUID())

        await #expect(throws: TimelineError.timelineNotFound) {
            try await handle.siblingRequest(appending: [LLMMessage(role: .user, content: "x")])
        }
    }

    @Test("in-flight Turn is a structured error")
    func inFlightTurn() async throws {
        let runtime = makeRuntime()
        let (timeline, _) = try await makeTimeline(in: runtime)

        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1]
        let handle = try await timeline.startTurn("hangs")

        await #expect(throws: TimelineError.siblingPrefixUnavailable(.turnInFlight)) {
            try await timeline.siblingRequest(appending: [LLMMessage(role: .user, content: "x")])
        }
        await handle.cancel()
        for await _ in handle.events() {}
    }
}
