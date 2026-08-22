import Foundation
import PKPrompt
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite(.serialized) struct ContextPipelineBuilderTests {
    // MARK: - Imperative Construction

    @Test("Imperative pipeline executes correct number of stages")
    func builder_executesCorrectStageCount() async throws {
        let tracker = StageRunTracker()
        let pipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent>()
            .add(TrackingStage(tracker: tracker, stageID: "a"))
            .add(TrackingStage(tracker: tracker, stageID: "b"))
            .add(TrackingStage(tracker: tracker, stageID: "c"))

        let context = ContextPipelineContext(
            query: "test", history: [], limit: 5,
            tagGenerator: nil, startTime: Date().timeIntervalSinceReferenceDate
        )
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        let runs = await tracker.runs
        #expect(runs == ["a", "b", "c"])
    }

    @Test("Imperative pipeline supports conditionally adding stages")
    func builder_supportsConditionalStages() async throws {
        let tracker = StageRunTracker()
        let includeExtra = shouldIncludeConditionalStage()
        var pipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent>()
            .add(TrackingStage(tracker: tracker, stageID: "always"))
        if includeExtra {
            pipeline = pipeline.add(TrackingStage(tracker: tracker, stageID: "conditional"))
        }

        let context = ContextPipelineContext(
            query: "test", history: [], limit: 5,
            tagGenerator: nil, startTime: Date().timeIntervalSinceReferenceDate
        )
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        let runs = await tracker.runs
        #expect(runs == ["always"])
    }

    // MARK: - Custom Pipeline Injection

    @Test("TurnBriefingBuilder uses injected custom pipeline")
    func turnBriefingBuilder_usesCustomPipeline() async throws {
        let tracker = StageRunTracker()
        let customPipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent>()
            .add(TrackingStage(tracker: tracker, stageID: "custom"))
            .add(CompletionStage())

        let manager = TurnBriefingBuilder(workspace: nil, pipeline: customPipeline)

        let stream = await manager.gatherContext(for: "test")
        var sawComplete = false
        for try await event in stream {
            if case .complete = event { sawComplete = true }
        }

        let runs = await tracker.runs
        #expect(runs == ["custom"])
        #expect(sawComplete)
    }

    @Test("TurnBriefingBuilder uses override pipeline in gatherContext")
    func turnBriefingBuilder_usesOverridePipeline() async throws {
        let tracker = StageRunTracker()
        let overridePipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent>()
            .add(TrackingStage(tracker: tracker, stageID: "override"))
            .add(CompletionStage())

        let manager = TurnBriefingBuilder(workspace: nil) // Uses default pipeline internally

        let stream = await manager.gatherContext(for: "test", overridePipeline: overridePipeline)
        var sawComplete = false
        for try await event in stream {
            if case .complete = event { sawComplete = true }
        }

        let runs = await tracker.runs
        #expect(runs == ["override"])
        #expect(sawComplete)
    }

    @Test("TurnBriefingBuilder default pipeline emits complete event")
    func turnBriefingBuilder_defaultPipeline_completes() async throws {
        let manager = TurnBriefingBuilder(workspace: nil)

        let stream = await manager.gatherContext(for: "hello")
        var sawComplete = false
        for try await event in stream {
            if case .complete = event { sawComplete = true }
        }
        #expect(sawComplete)
    }

    // MARK: - setResults Optional Semantics (Issue 6)

    @Test("setResults with nil does not overwrite existing values")
    func setResults_nilPreservesExisting() async {
        let context = ContextPipelineContext(
            query: "q", history: [], limit: 5,
            tagGenerator: nil, startTime: Date().timeIntervalSinceReferenceDate
        )
        await context.setResults(tags: ["a", "b"])
        // Calling with nil (default) should preserve tags
        await context.setResults(notes: [ContextNote(name: "n", content: "c", source: "s")])

        #expect(await context.generatedTags == ["a", "b"])
        #expect(await context.notes.count == 1)
    }

    @Test("setResults with empty array explicitly clears the field")
    func setResults_emptyArrayClears() async {
        let context = ContextPipelineContext(
            query: "q", history: [], limit: 5,
            tagGenerator: nil, startTime: Date().timeIntervalSinceReferenceDate
        )
        await context.setResults(tags: ["a", "b"])
        // Explicitly passing [] should clear
        await context.setResults(tags: [])

        #expect(await context.generatedTags.isEmpty)
    }
}

// MARK: - Test Helpers

private actor StageRunTracker {
    var runs: [String] = []
    func record(_ id: String) {
        runs.append(id)
    }
}

private struct TrackingStage: PipelineStage {
    let tracker: StageRunTracker
    let stageID: String

    var id: String {
        stageID
    }

    func process(
        _: ContextPipelineContext
    ) async throws -> AsyncThrowingStream<ContextGatheringEvent, Error> {
        await tracker.record(stageID)
        return AsyncThrowingStream { $0.finish() }
    }
}

/// A minimal stage that assembles a ContextData so the manager's stream emits .complete.
private struct CompletionStage: PipelineStage {
    func process(
        _ context: ContextPipelineContext
    ) async throws -> AsyncThrowingStream<ContextGatheringEvent, Error> {
        await context.finalize(executionTime: 0)
        return AsyncThrowingStream { $0.finish() }
    }
}

private func shouldIncludeConditionalStage() -> Bool {
    false
}
