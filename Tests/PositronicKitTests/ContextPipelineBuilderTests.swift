import Foundation
import PKPrompt
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite(.serialized) struct ContextPipelineBuilderTests {
    // MARK: - DSL Construction

    @Test("DSL builds pipeline that executes correct number of stages")
    func builder_executesCorrectStageCount() async throws {
        let tracker = StageRunTracker()
        let pipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent> {
            TrackingStage(tracker: tracker, stageID: "a")
            TrackingStage(tracker: tracker, stageID: "b")
            TrackingStage(tracker: tracker, stageID: "c")
        }

        let context = ContextPipelineContext(
            query: "test", history: [], limit: 5,
            tagGenerator: nil, startTime: CFAbsoluteTimeGetCurrent()
        )
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        let runs = await tracker.runs
        #expect(runs == ["a", "b", "c"])
    }

    @Test("DSL supports conditional stages via if")
    func builder_supportsConditionalStages() async throws {
        let tracker = StageRunTracker()
        let includeExtra = false
        let pipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent> {
            TrackingStage(tracker: tracker, stageID: "always")
            if includeExtra {
                TrackingStage(tracker: tracker, stageID: "conditional")
            }
        }

        let context = ContextPipelineContext(
            query: "test", history: [], limit: 5,
            tagGenerator: nil, startTime: CFAbsoluteTimeGetCurrent()
        )
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        let runs = await tracker.runs
        #expect(runs == ["always"])
    }

    // MARK: - Custom Pipeline Injection

    @Test("ContextManager uses injected custom pipeline")
    func contextManager_usesCustomPipeline() async throws {
        let tracker = StageRunTracker()
        let customPipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent> {
            TrackingStage(tracker: tracker, stageID: "custom")
            CompletionStage()
        }

        let manager = ContextManager(workspace: nil, pipeline: customPipeline)

        let stream = await manager.gatherContext(for: "test")
        var sawComplete = false
        for try await event in stream {
            if case .complete = event { sawComplete = true }
        }

        let runs = await tracker.runs
        #expect(runs == ["custom"])
        #expect(sawComplete)
    }

    @Test("ContextManager uses override pipeline in gatherContext")
    func contextManager_usesOverridePipeline() async throws {
        let tracker = StageRunTracker()
        let overridePipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent> {
            TrackingStage(tracker: tracker, stageID: "override")
            CompletionStage()
        }

        let manager = ContextManager(workspace: nil) // Uses default pipeline internally

        let stream = await manager.gatherContext(for: "test", overridePipeline: overridePipeline)
        var sawComplete = false
        for try await event in stream {
            if case .complete = event { sawComplete = true }
        }

        let runs = await tracker.runs
        #expect(runs == ["override"])
        #expect(sawComplete)
    }

    @Test("ContextManager default pipeline emits complete event")
    func contextManager_defaultPipeline_completes() async throws {
        let manager = ContextManager(workspace: nil)

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
            tagGenerator: nil, startTime: CFAbsoluteTimeGetCurrent()
        )
        await context.setResults(tags: ["a", "b"])
        // Calling with nil (default) should preserve tags
        await context.setResults(notes: [ContextFile(name: "n", content: "c", source: "s")])

        #expect(await context.generatedTags == ["a", "b"])
        #expect(await context.notes.count == 1)
    }

    @Test("setResults with empty array explicitly clears the field")
    func setResults_emptyArrayClears() async {
        let context = ContextPipelineContext(
            query: "q", history: [], limit: 5,
            tagGenerator: nil, startTime: CFAbsoluteTimeGetCurrent()
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
