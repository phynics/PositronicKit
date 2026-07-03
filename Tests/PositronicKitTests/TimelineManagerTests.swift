import Foundation
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

struct TimelineManagerTests {
    @Test("Test Session Creation and Context Manager Access")
    func sessionCreation() async throws {
        let workspace = TestWorkspace()
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

    @Test("Test Stale Session Cleanup")
    func cleanup() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)

        let session = try await timelineManager.createTimeline()

        await timelineManager.cleanupStaleTimelines(maxAge: 0)

        let retrieved = await timelineManager.getTimeline(id: session.id)
        #expect(retrieved == nil, "Session should be cleaned up")
    }

    @Test("deleteTimeline(id:) evicts the prompt-history registry entry, not just the cache")
    func deleteTimelineEvictsPromptHistory() async throws {
        let workspace = TestWorkspace()
        let registry = TimelinePromptHistoryRegistry()
        let timelineManager = TimelineManager(
            workspaceRoot: workspace.root,
            promptHistoryRegistry: registry
        )

        let session = try await timelineManager.createTimeline()

        // Populate the registry with distinguishing state.
        let history = await registry.history(for: session.id)
        await history.recordAppend(messageCount: 3, estimatedTokens: 90)
        #expect(await history.appendedMessageCount == 3)

        // deleteTimeline is the runtime-eviction seam: cache + registry.
        await timelineManager.deleteTimeline(id: session.id)

        // Cache evicted.
        #expect(await timelineManager.getTimeline(id: session.id) == nil)

        // Registry evicted — re-fetch yields a fresh instance with reset state.
        let fresh = await registry.history(for: session.id)
        #expect(await fresh.appendedMessageCount == 0)
        #expect(await fresh.appendedTokens == 0)
        #expect(await fresh.lastDiff == nil)
    }

    @Test("cleanupStaleTimelines(maxAge:) also drops the prompt-history registry entry")
    func cleanupStaleEvictsPromptHistory() async throws {
        let workspace = TestWorkspace()
        let registry = TimelinePromptHistoryRegistry()
        let timelineManager = TimelineManager(
            workspaceRoot: workspace.root,
            promptHistoryRegistry: registry
        )

        let session = try await timelineManager.createTimeline()

        let history = await registry.history(for: session.id)
        await history.recordAppend(messageCount: 5, estimatedTokens: 150)
        #expect(await history.appendedMessageCount == 5)

        await timelineManager.cleanupStaleTimelines(maxAge: 0)

        #expect(await timelineManager.getTimeline(id: session.id) == nil)

        let fresh = await registry.history(for: session.id)
        #expect(await fresh.appendedMessageCount == 0)
        #expect(await fresh.appendedTokens == 0)
    }

    @Test("deleteTimeline(id:) with no injected registry still evicts the cache")
    func deleteTimelineWithoutRegistry() async throws {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)

        let session = try await timelineManager.createTimeline()

        await timelineManager.deleteTimeline(id: session.id)

        #expect(await timelineManager.getTimeline(id: session.id) == nil)
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

    @Test("Default runtime tool set includes filesystem and timeline observation tools")
    func defaultToolManagerContract() async {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)
        let timeline = Timeline(workingDirectory: workspace.root.path)
        let toolManager = await timelineManager.createToolManager(
            for: timeline,
            jailRoot: workspace.root.path,
            toolContextTimeline: ToolTimelineContext()
        )

        let toolIds = Set(await toolManager.getAvailableTools().map(\.id))
        #expect(toolIds == [
            "change_directory",
            "ls",
            "find",
            "grep",
            "search_files",
            "cat",
            "timeline_list",
            "timeline_peek",
        ])
        #expect(!toolIds.contains("timeline_send"))
    }

    @Test("Timeline send is installed only when an agent is attached")
    func timelineSendRequiresAttachedAgent() async {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(workspaceRoot: workspace.root)
        let timeline = Timeline(
            workingDirectory: workspace.root.path,
            attachedAgentInstanceId: UUID()
        )
        let toolManager = await timelineManager.createToolManager(
            for: timeline,
            jailRoot: workspace.root.path,
            toolContextTimeline: ToolTimelineContext()
        )

        let toolIds = Set(await toolManager.getAvailableTools().map(\.id))
        #expect(toolIds.contains("timeline_send"))
    }

    @Test("Selective runtime tool policy disables chosen categories only")
    func selectiveRuntimeToolPolicy() async {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            workspaceRoot: workspace.root,
            runtimeToolPolicy: .init(
                installFilesystemTools: false,
                installTimelineObservationTools: true,
                installTimelineSendTool: true
            )
        )
        let timeline = Timeline(
            workingDirectory: workspace.root.path,
            attachedAgentInstanceId: UUID()
        )
        let toolManager = await timelineManager.createToolManager(
            for: timeline,
            jailRoot: workspace.root.path,
            toolContextTimeline: ToolTimelineContext()
        )

        let toolIds = Set(await toolManager.getAvailableTools().map(\.id))
        #expect(toolIds == ["timeline_list", "timeline_peek", "timeline_send"])
    }

    @Test("Deny-all runtime tool policy installs no default tools")
    func denyAllRuntimeToolPolicy() async {
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            workspaceRoot: workspace.root,
            runtimeToolPolicy: .denyAll
        )
        let timeline = Timeline(
            workingDirectory: workspace.root.path,
            attachedAgentInstanceId: UUID()
        )
        let toolManager = await timelineManager.createToolManager(
            for: timeline,
            jailRoot: workspace.root.path,
            toolContextTimeline: ToolTimelineContext()
        )

        let toolIds = Set(await toolManager.getAvailableTools().map(\.id))
        #expect(toolIds.isEmpty)
    }
}
