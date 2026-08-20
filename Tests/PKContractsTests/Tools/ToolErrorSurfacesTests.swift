import Foundation
@testable import PKContracts
import Testing

final class ToolErrorSurfacesTests {
    @Test
    func toolNotFound() {
        let error = ToolError.toolNotFound("missing_tool")
        #expect(error.errorDomain == PKErrorDomain.tool)
        #expect(error.errorCode == 204)
        #expect(error == .toolNotFound("missing_tool"))
    }

    @Test
    func attachedToolsDisallowedOnPrivateThread() {
        let error = ToolError.attachedToolsDisallowedOnPrivateThread
        #expect(error.errorDomain == PKErrorDomain.tool)
        #expect(error.errorCode == 207)
        #expect(!error.userFriendlyMessage.contains("attached-workspace"))
        #expect(!((error.remediation ?? "").contains("attached-workspace")))
    }

    @Test
    func attachedToolsDisallowedOnPrivateThreadPreservesIdentity() {
        let error = ToolError.attachedToolsDisallowedOnPrivateThread

        #expect(error.errorDomain == PKErrorDomain.tool)
        #expect(error.errorCode == 207)
        #expect(error == .attachedToolsDisallowedOnPrivateThread)
    }

    @Test
    func workspaceNotFound() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let error = ToolError.workspaceNotFound(id)
        #expect(error.errorDomain == PKErrorDomain.tool)
        #expect(error.errorCode == 205)
        #expect(error == .workspaceNotFound(id))
    }

    @Test
    func requestOriginUnavailable() {
        let error = ToolError.requestOriginUnavailable
        #expect(error.errorDomain == PKErrorDomain.tool)
        #expect(error.errorCode == 206)
    }

    @Test
    func invalidArgument() {
        let error = ToolError.invalidArgument("count", expected: "Int", got: "String")
        #expect(error.errorDomain == PKErrorDomain.tool)
        #expect(error.errorCode == 202)
        #expect(error == .invalidArgument("count", expected: "Int", got: "String"))
    }

    @Test
    func missingArgument() {
        let error = ToolError.missingArgument("query")
        #expect(error.errorDomain == PKErrorDomain.tool)
        #expect(error.errorCode == 201)
        #expect(error == .missingArgument("query"))
    }

    @Test
    func executionFailed() {
        let error = ToolError.executionFailed("Timeout")
        #expect(error.errorDomain == PKErrorDomain.tool)
        #expect(error.errorCode == 203)
        #expect(error == .executionFailed("Timeout"))
    }

    @Test
    func timedOutButMayStillBeRunning() {
        // PKRR-004: distinct terminal state for mutating/external-process tools abandoned
        // after a wall-clock timeout. Typed case (carries the timeout value, not a string).
        let error = ToolError.timedOutButMayStillBeRunning(timeout: 0.5)
        #expect(error.errorDomain == PKErrorDomain.tool)
        #expect(error.errorCode == 212)
        #expect(error == .timedOutButMayStillBeRunning(timeout: 0.5))
        #expect(!error.isBlocked)
        #expect(error.userFriendlyMessage.contains("may still be running"))
        #expect(error.userFriendlyMessage.contains("0.5 seconds"))
        #expect((error.remediation ?? "").contains("duplicate"))
    }

    @Test
    func timeoutDescriptionFormatsIntegersAndFractions() {
        // PKRR-004: shared formatter used by the clean-timeout and may-still-be-running
        // messages so the wording stays consistent across both terminal states.
        #expect(ToolError.timeoutDescription(60) == "60 seconds")
        #expect(ToolError.timeoutDescription(0.05) == "0.05 seconds")
        #expect(ToolError.timeoutDescription(1.5) == "1.5 seconds")
    }

    @Test
    func ambiguousWorkspaceToolProvidesACompleteCorrection() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let candidates = [
            WorkspaceToolCandidate(
                workspaceID: firstID,
                label: "primary",
                toolID: "read_file",
                toolName: "Read file",
                description: "Reads a file",
                parametersSchema: ["type": .string("object")],
                isPrimary: true
            ),
            WorkspaceToolCandidate(
                workspaceID: secondID,
                label: "project",
                toolID: "read_file",
                toolName: "Read file",
                description: "Reads a project file",
                parametersSchema: ["type": .string("object")]
            ),
        ]
        let error = ToolError.ambiguousWorkspaceTool(tool: "read_file", candidates: candidates)

        #expect(error.errorCode == 214)
        #expect(error.userFriendlyMessage.contains("primary"))
        #expect((error.remediation ?? "").contains(firstID.uuidString))
        #expect((error.remediation ?? "").contains("Read file"))
        #expect((error.remediation ?? "").contains("schema"))
        #expect((error.remediation ?? "").contains("call_tool(tool: \"read_file\""))
    }

    @Test
    func reservedToolNameIsModelVisible() {
        let error = ToolError.reservedToolName("call_tool")
        #expect(error.errorCode == 215)
        #expect(error.userFriendlyMessage.contains("reserved"))
        #expect((error.remediation ?? "").contains("call_tool"))
    }
}
