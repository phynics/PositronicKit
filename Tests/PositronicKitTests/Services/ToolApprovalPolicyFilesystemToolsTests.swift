import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Enforcement of `ToolApprovalPolicy` does NOT live in `PKShared` — `ToolApprovalPolicy.swift` there
/// only defines the protocol and the two default gate implementations (`DenyAllToolApprovalPolicy`,
/// `AllowAllToolApprovalPolicy`). The actual gate consultation and denial happens at the runtime
/// execution sink in `PositronicKit`'s `Sources/PositronicKit/Services/Tools/ToolRouter.swift`
/// (in the private local-execution path): a tool whose `requiresPermission` is `true` is blocked
/// from running unless `approvalPolicy.requestApproval(tool:arguments:)` returns `.approve`; denial
/// throws `ToolError.permissionDenied(<tool.name>)`. This suite pins that enforcement across every
/// current PKShared filesystem tool, since a regression here would silently grant tool access.
///
/// This file mirrors the fixtures already established in `ToolRouterTests.swift` (`RecordingGate`,
/// `setupRouter`, `setupTimelineManager`) rather than importing them, because those helpers are
/// `private` to that file's `ToolRouterTests` class and there is no shared PKTestSupport extension
/// point for them yet; duplicating the minimal set here keeps this suite self-contained without
/// widening the visibility of another file's test-only internals.
final class ToolApprovalPolicyFilesystemToolsTests {
    /// Records every gate consultation so a test can assert whether the gate was reached at all.
    final class RecordingGate: ToolApprovalPolicy, @unchecked Sendable {
        let decision: ToolApprovalDecision
        private(set) var consultedToolIds: [String] = []

        init(decision: ToolApprovalDecision) {
            self.decision = decision
        }

        func requestApproval(tool: AnyTool, arguments _: [String: AnyCodable]) async -> ToolApprovalDecision {
            consultedToolIds.append(tool.callName)
            return decision
        }
    }

    private func setupTimelineManager() async throws -> (TimelineManager, MockPersistenceService) {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: workspace.root
        )
        return (timelineManager, mockPersistence)
    }

    /// Builds a timeline with a single registered tool and returns the router under test.
    /// When `approvalPolicy` is nil, `ToolRouter`'s own default gate is used (currently
    /// `DenyAllToolApprovalPolicy`), to pin the default-deny posture explicitly.
    private func setupRouter(
        with tool: any PKShared.Tool,
        approvalPolicy: (any ToolApprovalPolicy)? = nil
    ) async throws -> (ToolRouter, UUID) {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = if let approvalPolicy {
            ToolRouter(
                timelineManager: timelineManager,
                messageStore: mockPersistence,
                approvalPolicy: approvalPolicy
            )
        } else {
            ToolRouter(
                timelineManager: timelineManager,
                messageStore: mockPersistence
            )
        }

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(tool.callName))

        let toolManager = await timelineManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([tool.toAnyTool()])

        return (toolRouter, session.id)
    }

    /// The 5 filesystem tools that currently declare `requiresPermission == true`. Driving the
    /// parameterized tests off each tool's own `requiresPermission` flag (rather than only trusting
    /// this list) means a future contributor who flips a tool's flag without updating this array
    /// still gets caught by the accompanying `allListedToolsActuallyRequirePermission` guard below.
    private static let permissionedFilesystemTools: [any PKShared.Tool] = [
        ReadFileTool(currentDirectory: NSTemporaryDirectory()),
        ListDirectoryTool(currentDirectory: NSTemporaryDirectory()),
        FindFileTool(currentDirectory: NSTemporaryDirectory()),
        SearchFilesTool(currentDirectory: NSTemporaryDirectory()),
        SearchFileContentTool(currentDirectory: NSTemporaryDirectory()),
    ]

    @Test("Guard: every tool listed as permissioned actually declares requiresPermission == true")
    func allListedToolsActuallyRequirePermission() {
        for tool in Self.permissionedFilesystemTools {
            #expect(tool.requiresPermission, "\(tool.callName) is listed as permissioned but requiresPermission is false")
        }
    }

    @Test("Every permissioned filesystem tool is blocked when the approval gate denies it", arguments: [
        "cat", "ls", "find", "search_files", "grep",
    ])
    func permissionedFilesystemToolBlockedWhenDenied(toolId: String) async throws {
        let tool = try #require(Self.permissionedFilesystemTools.first { $0.callName == toolId })
        let gate = RecordingGate(decision: .deny)
        let (router, timelineId) = try await setupRouter(with: tool, approvalPolicy: gate)

        do {
            _ = try await router.execute(tool: .known(tool.callName), arguments: [:], timelineId: timelineId)
            Issue.record("Expected permissionDenied to be thrown for \(tool.callName)")
        } catch ToolError.permissionDenied(tool.name) {
            // expected
        } catch {
            Issue.record("Unexpected error for \(tool.callName): \(error)")
        }

        #expect(gate.consultedToolIds == [tool.callName])
    }

    @Test("ReadFileTool executes end-to-end when the approval gate approves it")
    func readFileToolRunsWhenApproved() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("hello.txt")
        try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = ReadFileTool(currentDirectory: tempDir.path)
        let gate = RecordingGate(decision: .approve)
        let (router, timelineId) = try await setupRouter(with: tool, approvalPolicy: gate)

        let result = try await router.execute(
            tool: .known(tool.callName),
            arguments: ["path": AnyCodable("hello.txt")],
            timelineId: timelineId
        )

        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome, got \(result)")
            return
        }
        #expect(output.contains("hello world"))
        #expect(gate.consultedToolIds == [tool.callName])
    }

    @Test("ChangeDirectoryTool bypasses the approval gate entirely (requiresPermission == false)")
    func changeDirectoryToolBypassesGate() async throws {
        let tool = ChangeDirectoryTool(currentPath: NSTemporaryDirectory()) { _ in }
        #expect(tool.requiresPermission == false)

        let gate = RecordingGate(decision: .deny)
        let (router, timelineId) = try await setupRouter(with: tool, approvalPolicy: gate)

        do {
            _ = try await router.execute(
                tool: .known(tool.callName),
                arguments: ["path": AnyCodable(NSTemporaryDirectory())],
                timelineId: timelineId
            )
        } catch ToolError.permissionDenied {
            Issue.record("ChangeDirectoryTool must never be blocked by the approval gate")
        } catch {
            // Any other failure (e.g. path resolution) is acceptable here; the load-bearing
            // assertion is that the gate was never consulted, checked below.
        }

        #expect(gate.consultedToolIds.isEmpty)
    }

    @Test("Absent an explicit gate, ToolRouter's default gate denies a permissioned filesystem tool")
    func defaultGateDeniesPermissionedToolByDefault() async throws {
        let tool = ReadFileTool(currentDirectory: NSTemporaryDirectory())
        let (router, timelineId) = try await setupRouter(with: tool, approvalPolicy: nil)

        do {
            _ = try await router.execute(tool: .known(tool.callName), arguments: [:], timelineId: timelineId)
            Issue.record("Expected permissionDenied to be thrown under the default gate")
        } catch ToolError.permissionDenied(tool.name) {
            // expected — confirms ToolRouter's default approvalPolicy is DenyAllToolApprovalPolicy
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("permissionDenied has a stable, pinned errorCode")
    func permissionDeniedErrorCodeIsStable() {
        #expect(ToolError.permissionDenied("any_tool").errorCode == 210)
    }
}
