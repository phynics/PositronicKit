import Foundation
@testable import PKContracts
import Testing

// MARK: - ToolError v1 model contract tests

struct ToolErrorModelTests {
    @Test("All v1 error categories have distinct error codes")
    func distinctErrorCodes() {
        let codes: Set<Int> = [
            ToolError.missingArgument("x").errorCode,
            ToolError.invalidArgument("x", expected: "Int", got: "String").errorCode,
            ToolError.malformedArguments("bad").errorCode,
            ToolError.schemaMismatch("bad").errorCode,
            ToolError.executionFailed("fail").errorCode,
            ToolError.timedOutButMayStillBeRunning(timeout: 30).errorCode,
            ToolError.toolNotFound("t").errorCode,
            ToolError.workspaceNotFound(UUID()).errorCode,
            ToolError.requestOriginUnavailable.errorCode,
            ToolError.attachedToolsDisallowedOnPrivateThread.errorCode,
            ToolError.permissionDenied("t").errorCode,
            ToolError.unmatchedToolOutput("call_1").errorCode,
            ToolError.invalidWorkspaceID("bad").errorCode,
        ]
        #expect(codes.count == 13)
    }

    @Test("All v1 error categories have non-empty user-friendly messages")
    func nonEmptyUserFriendlyMessages() {
        let errors: [ToolError] = [
            .missingArgument("param"),
            .invalidArgument("param", expected: "Int", got: "String"),
            .malformedArguments("not JSON"),
            .schemaMismatch("missing required field"),
            .executionFailed("timeout"),
            .timedOutButMayStillBeRunning(timeout: 30),
            .toolNotFound("unknown"),
            .workspaceNotFound(UUID()),
            .requestOriginUnavailable,
            .attachedToolsDisallowedOnPrivateThread,
            .permissionDenied("tool"),
            .unmatchedToolOutput("call_1"),
            .invalidWorkspaceID("not-a-uuid"),
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
            .timedOutButMayStillBeRunning(timeout: 30),
            .toolNotFound("unknown"),
            .workspaceNotFound(UUID()),
            .requestOriginUnavailable,
            .attachedToolsDisallowedOnPrivateThread,
            .permissionDenied("tool"),
            .unmatchedToolOutput("call_1"),
            .invalidWorkspaceID("not-a-uuid"),
        ]
        for err in errors {
            #expect(err.remediation != nil, "Missing remediation for \(err)")
        }
    }
}
