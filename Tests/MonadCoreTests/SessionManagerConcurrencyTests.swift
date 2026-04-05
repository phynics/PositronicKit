import Dependencies
import Foundation
@testable import MonadCore
@testable import MonadShared
import MonadTestSupport
import Testing

@Suite(.serialized) struct TimelineManagerConcurrencyTests {
    private func makeTimelineManager() async throws -> TimelineManager {
        let workspace = TestWorkspace()

        return try await TestDependencies()
            .withMocks()
            .run {
                TimelineManager(workspaceRoot: workspace.root)
            }
    }

    @Test("Concurrent createTimeline calls each produce a unique session ID")
    func concurrentCreate_uniqueIds() async throws {
        let manager = try await makeTimelineManager()

        let concurrency = 5
        let sessions = try await withThrowingTaskGroup(of: Timeline.self, returning: [Timeline].self) { group in
            for _ in 0 ..< concurrency {
                group.addTask {
                    try await manager.createTimeline()
                }
            }
            var results: [Timeline] = []
            for try await session in group {
                results.append(session)
            }
            return results
        }

        #expect(sessions.count == concurrency)
        let ids = Set(sessions.map { $0.id })
        #expect(ids.count == concurrency, "All sessions must have distinct IDs")
    }

    @Test("Concurrent createTimeline calls all succeed without data corruption")
    func concurrentCreate_noDataCorruption() async throws {
        let manager = try await makeTimelineManager()

        let sessions = try await withThrowingTaskGroup(of: Timeline.self, returning: [Timeline].self) { group in
            for index in 0 ..< 4 {
                group.addTask {
                    try await manager.createTimeline(title: "Session \(index)")
                }
            }
            var results: [Timeline] = []
            for try await session in group {
                results.append(session)
            }
            return results
        }

        for session in sessions {
            #expect(!session.id.uuidString.isEmpty)
            #expect(!session.title.isEmpty)
        }
    }

    @Test("getTimeline returns nil for unknown ID")
    func getTimeline_unknownId_returnsNil() async throws {
        let manager = try await makeTimelineManager()
        let session = await manager.getTimeline(id: UUID())
        #expect(session == nil)
    }

    @Test("createTimeline then getTimeline returns the created session")
    func createTimeline_thenGet_returnsSession() async throws {
        let manager = try await makeTimelineManager()
        let created = try await manager.createTimeline(title: "Test Session")
        let fetched = await manager.getTimeline(id: created.id)
        #expect(fetched?.id == created.id)
    }

    @Test("Concurrent getTimeline calls for different IDs return nil without conflict")
    func concurrentGet_differentIds_allReturnNil() async throws {
        let manager = try await makeTimelineManager()
        let ids = (0 ..< 10).map { _ in UUID() }

        let results = await withTaskGroup(of: Timeline?.self, returning: [Timeline?].self) { group in
            for id in ids {
                group.addTask {
                    await manager.getTimeline(id: id)
                }
            }
            var output: [Timeline?] = []
            for await result in group {
                output.append(result)
            }
            return output
        }

        #expect(results.allSatisfy { $0 == nil })
    }
}
