import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import struct PositronicKit.Thread
import Testing

@Suite(.serialized) struct ThreadManagerConcurrencyTests {
    private func makeThreadManager() async throws -> ThreadManager {
        let workspace = TestWorkspace()
        return ThreadManager(workspaceProfile: .hostManaged(root: workspace.root))
    }

    @Test("Concurrent createThread calls each produce a unique thread ID")
    func concurrentCreate_uniqueIds() async throws {
        let manager = try await makeThreadManager()

        let concurrency = 5
        let sessions = try await withThrowingTaskGroup(of: Thread.self, returning: [Thread].self) { group in
            for _ in 0 ..< concurrency {
                group.addTask {
                    try await manager.createThread()
                }
            }
            var results: [Thread] = []
            for try await session in group {
                results.append(session)
            }
            return results
        }

        #expect(sessions.count == concurrency)
        let ids = Set(sessions.map { $0.id })
        #expect(ids.count == concurrency, "All sessions must have distinct IDs")
    }

    @Test("Concurrent createThread calls all succeed without data corruption")
    func concurrentCreate_noDataCorruption() async throws {
        let manager = try await makeThreadManager()

        let sessions = try await withThrowingTaskGroup(of: Thread.self, returning: [Thread].self) { group in
            for index in 0 ..< 4 {
                group.addTask {
                    try await manager.createThread(title: "Session \(index)")
                }
            }
            var results: [Thread] = []
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

    @Test("thread returns nil for unknown ID")
    func getThread_unknownId_returnsNil() async throws {
        let manager = try await makeThreadManager()
        let session = await manager.thread(id: UUID())
        #expect(session == nil)
    }

    @Test("createThread then thread returns the created thread")
    func createThread_thenGet_returnsSession() async throws {
        let manager = try await makeThreadManager()
        let created = try await manager.createThread(title: "Test Session")
        let fetched = await manager.thread(id: created.id)
        #expect(fetched?.id == created.id)
    }

    @Test("Concurrent thread calls for different IDs return nil without conflict")
    func concurrentGet_differentIds_allReturnNil() async throws {
        let manager = try await makeThreadManager()
        let ids = (0 ..< 10).map { _ in UUID() }

        let results = await withTaskGroup(of: Thread?.self, returning: [Thread?].self) { group in
            for id in ids {
                group.addTask {
                    await manager.thread(id: id)
                }
            }
            var output: [Thread?] = []
            for await result in group {
                output.append(result)
            }
            return output
        }

        #expect(results.allSatisfy { $0 == nil })
    }
}
