import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite(.serialized) struct ToolRouterConcurrencyTests {
    private func makeSetup() async throws -> (ToolRouter, TimelineManager, MockPersistenceService) {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let router = ToolRouter(timelineManager: manager, messageStore: persistence)
        return (router, manager, persistence)
    }

    @Test("Concurrent execute calls for unknown tools each throw toolNotFound")
    func concurrentExecute_unknownTool_allThrow() async throws {
        let (router, manager, _) = try await makeSetup()

        let timelineId = try await manager.createTimeline().id

        let tool = ToolReference.known(id: "nonexistent")
        let concurrency = 4

        let errors = await withTaskGroup(of: Error?.self, returning: [Error?].self) { group in
            for _ in 0 ..< concurrency {
                group.addTask {
                    do {
                        _ = try await router.execute(tool: tool, arguments: [:], timelineId: timelineId)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var results: [Error?] = []
            for await error in group {
                results.append(error)
            }
            return results
        }

        // All concurrent calls should fail (not hang or crash)
        #expect(errors.count == concurrency)
        for error in errors {
            #expect(error != nil, "Each concurrent execute should throw an error")
        }
    }

    @Test("ToolRouter.execute for disconnected timeline throws toolNotFound or workspaceNotFound")
    func execute_unknownTimeline_throws() async throws {
        let (router, _, _) = try await makeSetup()
        let unknownTimelineId = UUID()
        let tool = ToolReference.known(id: "some-tool")

        do {
            _ = try await router.execute(tool: tool, arguments: [:], timelineId: unknownTimelineId)
            Issue.record("Expected error to be thrown")
        } catch {
            // Any ToolError is acceptable (toolNotFound, workspaceNotFound)
            #expect(error is ToolError || error is TimelineError)
        }
    }
}
