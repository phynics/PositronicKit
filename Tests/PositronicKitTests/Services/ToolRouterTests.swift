import Dependencies
import Foundation
@testable import PositronicKit
@testable import PKShared
import PKTestSupport
import Testing

@Suite final class ToolRouterTests {
    struct MockTool: PKShared.Tool, @unchecked Sendable {
        let id: String
        let name: String
        let description = "A mock tool for testing"
        let requiresPermission = false
        var parametersSchema: [String: AnyCodable] {
            [:]
        }

        var result: ToolResult

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            if !result.success, result.error == "client_tools_disallowed_on_private_timeline" {
                throw ToolError.attachedToolsDisallowedOnPrivateTimeline
            }
            return result
        }
    }

    private func setupTimelineManager() async throws -> (TimelineManager, MockPersistenceService) {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = try await TestDependencies()
            .withMocks(persistence: mockPersistence)
            .run {
                TimelineManager(workspaceRoot: workspace.root)
            }
        return (timelineManager, mockPersistence)
    }

    @Test

    func executeLocally() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = withDependencies {
            $0.timelineManager = timelineManager
        } operation: {
            ToolRouter()
        }

        // Setup session and local workspace
        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://local")), location: .runtime, originId: nil)

        // Mock persistence expects WorkspaceReference
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)

        // Setup internal tools by extracting the ToolManager
        let toolManager = await timelineManager.getToolManager(for: session.id)
        try #require(toolManager != nil)

        let toolId = "local_tool"
        let mockTool = MockTool(id: toolId, name: toolId, result: .success("Local success"))
        await toolManager?.updateAvailableTools([mockTool.toAnyTool()])

        // The mock persistence doesn't automatically wire tool IDs to workspaces for `findWorkspaceForTool`
        // We simulate `addToolToWorkspace` or just rely on the tool manager falling back to the candidates.
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = ["param": AnyCodable("value")]

        let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome")
            return
        }
        #expect(output == "Local success")
    }

    @Test

    func attachedWorkspaceToolDefersExternalExecution() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = withDependencies {
            $0.timelineManager = timelineManager
        } operation: {
            ToolRouter()
        }

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()

        // Setup attached workspace
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://remote")), location: .attached, originId: UUID())
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)

        let toolId = "attached_tool"
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        do {
            let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
            guard case .deferredExternally = result else {
                Issue.record("Expected .deferredExternally")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test

    func attachedWorkspaceToolWithoutOriginStillDefers() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = withDependencies {
            $0.timelineManager = timelineManager
        } operation: {
            ToolRouter()
        }

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()

        // Setup attached workspace missing an originId
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://remote")), location: .attached, originId: nil)
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)

        let toolId = "attached_tool"
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        do {
            let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
            guard case .deferredExternally = result else {
                Issue.record("Expected .deferredExternally")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test

    func executeToolNotFound() async throws {
        let (timelineManager, _) = try await setupTimelineManager()
        let toolRouter = withDependencies {
            $0.timelineManager = timelineManager
        } operation: {
            ToolRouter()
        }

        let session = try await timelineManager.createTimeline()
        let toolRef = ToolReference.known("unknown")
        let arguments: [String: AnyCodable] = [:]

        do {
            _ = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
            Issue.record("Should have thrown toolNotFound")
        } catch ToolError.toolNotFound {
            // Expected
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }
}

// MARK: - ParsedToolCall decode contract tests

@Suite struct ParsedToolCallTests {
    @Test("Valid JSON object decodes to non-nil arguments")
    func validJSONDecodes() {
        let call = ParsedToolCall(callId: "1", name: "test", argumentsJSON: "{\"key\": \"value\"}")
        #expect(call.arguments != nil)
        #expect(call.arguments?["key"]?.value as? String == "value")
    }

    @Test("Invalid JSON produces nil arguments, not empty dictionary")
    func invalidJSONProducesNil() {
        let call = ParsedToolCall(callId: "2", name: "test", argumentsJSON: "not json at all")
        #expect(call.arguments == nil)
    }

    @Test("Non-object JSON (array) produces nil arguments")
    func arrayJSONProducesNil() {
        let call = ParsedToolCall(callId: "3", name: "test", argumentsJSON: "[1,2,3]")
        #expect(call.arguments == nil)
    }

    @Test("Empty string produces nil arguments")
    func emptyStringProducesNil() {
        let call = ParsedToolCall(callId: "4", name: "test", argumentsJSON: "")
        #expect(call.arguments == nil)
    }

    @Test("Empty JSON object decodes to empty dictionary")
    func emptyObjectDecodes() {
        let call = ParsedToolCall(callId: "5", name: "test", argumentsJSON: "{}")
        #expect(call.arguments != nil)
        #expect(call.arguments?.isEmpty == true)
    }
}

// MARK: - ToolError v1 model contract tests

@Suite struct ToolErrorModelTests {
    @Test("All v1 error categories have distinct error codes")
    func distinctErrorCodes() {
        let codes: Set<Int> = [
            ToolError.missingArgument("x").errorCode,
            ToolError.invalidArgument("x", expected: "Int", got: "String").errorCode,
            ToolError.malformedArguments("bad").errorCode,
            ToolError.schemaMismatch("bad").errorCode,
            ToolError.executionFailed("fail").errorCode,
            ToolError.toolNotFound("t").errorCode,
            ToolError.workspaceNotFound(UUID()).errorCode,
            ToolError.requestOriginUnavailable.errorCode,
            ToolError.attachedToolsDisallowedOnPrivateTimeline.errorCode,
        ]
        #expect(codes.count == 9)
    }

    @Test("All v1 error categories have non-empty user-friendly messages")
    func nonEmptyUserFriendlyMessages() {
        let errors: [ToolError] = [
            .missingArgument("param"),
            .invalidArgument("param", expected: "Int", got: "String"),
            .malformedArguments("not JSON"),
            .schemaMismatch("missing required field"),
            .executionFailed("timeout"),
            .toolNotFound("unknown"),
            .workspaceNotFound(UUID()),
            .requestOriginUnavailable,
            .attachedToolsDisallowedOnPrivateTimeline,
        ]
        for err in errors {
            #expect(!err.userFriendlyMessage.isEmpty, "Empty message for \(err)")
        }
    }

    @Test("All v1 error categories have remediation guidance")
    func allHaveRemediation() {
        let errors: [ToolError] = [
            .missingArgument("param"),
            .invalidArgument("param", expected: "Int", got: "String"),
            .malformedArguments("not JSON"),
            .schemaMismatch("missing required field"),
            .executionFailed("timeout"),
            .toolNotFound("unknown"),
            .workspaceNotFound(UUID()),
            .requestOriginUnavailable,
            .attachedToolsDisallowedOnPrivateTimeline,
        ]
        for err in errors {
            #expect(err.remediation != nil, "Missing remediation for \(err)")
        }
    }
}

// MARK: - ToolParameters decode pattern tests

@Suite struct ToolParametersTests {
    @Test("require throws missingArgument when key absent")
    func requireMissing() {
        let params = ToolParameters([:])
        do {
            _ = try params.require("missing", as: String.self)
            Issue.record("Should have thrown missingArgument")
        } catch ToolError.missingArgument("missing") {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("require returns value when present and correct type")
    func requirePresent() throws {
        let params = ToolParameters(["name": "test"])
        let name = try params.require("name", as: String.self)
        #expect(name == "test")
    }

    @Test("require coerces Double to Int")
    func requireIntCoercion() throws {
        let params = ToolParameters(["count": 3.0])
        let count = try params.require("count", as: Int.self)
        #expect(count == 3)
    }

    @Test("require throws invalidArgument on type mismatch")
    func requireTypeMismatch() {
        let params = ToolParameters(["value": "string"])
        do {
            _ = try params.require("value", as: Int.self)
            Issue.record("Should have thrown invalidArgument")
        } catch let ToolError.invalidArgument(key, expected, got) {
            #expect(key == "value")
            #expect(expected == "Int")
            #expect(got == "String")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("optional returns nil when key absent")
    func optionalMissing() {
        let params = ToolParameters([:])
        let value = params.optional("missing", as: String.self)
        #expect(value == nil)
    }

    @Test("optional returns value when present")
    func optionalPresent() {
        let params = ToolParameters(["limit": 10])
        let limit = params.optional("limit", as: Int.self)
        #expect(limit == 10)
    }
}
