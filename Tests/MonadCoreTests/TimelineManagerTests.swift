import Dependencies
import Foundation
@testable import MonadCore
@testable import MonadShared
import MonadTestSupport
import Synchronization
import Testing

@Suite struct TimelineManagerTests {
    @Test("Test Session Creation and Context Manager Access")
    func sessionCreation() async throws {
        let workspace = TestWorkspace()

        try await TestDependencies()
            .withMocks()
            .run {
                let timelineManager = TimelineManager(workspaceRoot: workspace.root)

                let session = try await timelineManager.createTimeline()

                #expect(session.id != UUID(), "Session should have an ID")

                let retrievedSession = await timelineManager.getTimeline(id: session.id)
                #expect(retrievedSession != nil, "Should be able to retrieve created session")
                #expect(retrievedSession?.id == session.id)

                // Verify ContextManager is created and has access to workspace
                let contextManager = await timelineManager.getContextManager(for: session.id)
                #expect(contextManager != nil, "ContextManager should be created for session")
            }
    }

    @Test("Test Stale Session Cleanup")
    func cleanup() async throws {
        let workspace = TestWorkspace()

        try await TestDependencies()
            .withMocks()
            .run {
                let timelineManager = TimelineManager(workspaceRoot: workspace.root)

                let session = try await timelineManager.createTimeline()

                await timelineManager.cleanupStaleTimelines(maxAge: 0)

                let retrieved = await timelineManager.getTimeline(id: session.id)
                #expect(retrieved == nil, "Session should be cleaned up")
            }
    }

    @Test("Test Task Registration and Cancellation")
    func taskCancellation() async {
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let timelineManager = TimelineManager(workspaceRoot: workspaceRoot)
        let timelineId = UUID()

        let isCancelled = Mutex(false)

        let task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            isCancelled.withLock { $0 = true }
        }

        await timelineManager.registerTask(task, for: timelineId)

        // Verify it's in the registry (using internal access if possible, or just through behavior)
        await timelineManager.cancelGeneration(for: timelineId)

        // Wait a bit for task to finish
        for _ in 0 ..< 10 {
            let cancelled = isCancelled.withLock { $0 }
            if cancelled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let cancelledFinal = isCancelled.withLock { $0 }
        #expect(cancelledFinal, "Task should have been cancelled")
    }
}
