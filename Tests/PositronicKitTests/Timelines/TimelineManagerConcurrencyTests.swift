import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite(.serialized) struct TimelineManagerConcurrencyTests {
    private func makeTimelineManager() async throws -> TimelineManager {
        let workspace = TestWorkspace()
        return TimelineManager(workspaceProfile: .hostManaged(root: workspace.root))
    }

    @Test("Concurrent createTimeline calls each produce a unique timeline ID")
    func concurrentCreate_uniqueIds() async throws {
        let manager = try await makeTimelineManager()

        let concurrency = 5
        let timelines = try await withThrowingTaskGroup(of: TimelineRecord.self, returning: [TimelineRecord].self) { group in
            for _ in 0 ..< concurrency {
                group.addTask {
                    try await manager.createTimeline()
                }
            }
            var results: [TimelineRecord] = []
            for try await timeline in group {
                results.append(timeline)
            }
            return results
        }

        #expect(timelines.count == concurrency)
        let ids = Set(timelines.map { $0.id })
        #expect(ids.count == concurrency, "All timelines must have distinct IDs")
    }

    @Test("Concurrent createTimeline calls all succeed without data corruption")
    func concurrentCreate_noDataCorruption() async throws {
        let manager = try await makeTimelineManager()

        let timelines = try await withThrowingTaskGroup(of: TimelineRecord.self, returning: [TimelineRecord].self) { group in
            for index in 0 ..< 4 {
                group.addTask {
                    try await manager.createTimeline(title: "Timeline \(index)")
                }
            }
            var results: [TimelineRecord] = []
            for try await timeline in group {
                results.append(timeline)
            }
            return results
        }

        for timeline in timelines {
            #expect(!timeline.id.uuidString.isEmpty)
            #expect(!timeline.title.isEmpty)
        }
    }

    @Test("timeline returns nil for unknown ID")
    func getTimeline_unknownId_returnsNil() async throws {
        let manager = try await makeTimelineManager()
        let timeline = await manager.timeline(id: UUID())
        #expect(timeline == nil)
    }

    @Test("createTimeline then timeline returns the created timeline")
    func createTimeline_thenGet_returnsTimeline() async throws {
        let manager = try await makeTimelineManager()
        let created = try await manager.createTimeline(title: "Test Timeline")
        let fetched = await manager.timeline(id: created.id)
        #expect(fetched?.id == created.id)
    }

    @Test("Concurrent timeline calls for different IDs return nil without conflict")
    func concurrentGet_differentIds_allReturnNil() async throws {
        let manager = try await makeTimelineManager()
        let ids = (0 ..< 10).map { _ in UUID() }

        let results = await withTaskGroup(of: TimelineRecord?.self, returning: [TimelineRecord?].self) { group in
            for id in ids {
                group.addTask {
                    await manager.timeline(id: id)
                }
            }
            var output: [TimelineRecord?] = []
            for await result in group {
                output.append(result)
            }
            return output
        }

        #expect(results.allSatisfy { $0 == nil })
    }
}
