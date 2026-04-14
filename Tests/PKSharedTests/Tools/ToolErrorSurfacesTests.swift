import Foundation
@testable import PKShared
import Testing

final class ToolErrorSurfacesTests {
    @Test
    func toolNotFound() {
        let error = ToolError.toolNotFound("missing_tool")
        #expect(error.errorDomain == MonadErrorDomain.tool)
        #expect(error.errorCode == 204)
        #expect(error == .toolNotFound("missing_tool"))
    }

    @Test
    func clientToolsDisallowedOnPrivateTimeline() {
        let error = ToolError.clientToolsDisallowedOnPrivateTimeline
        #expect(error.errorDomain == MonadErrorDomain.tool)
        #expect(error.errorCode == 207)
    }

    @Test
    func workspaceNotFound() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let error = ToolError.workspaceNotFound(id)
        #expect(error.errorDomain == MonadErrorDomain.tool)
        #expect(error.errorCode == 205)
        #expect(error == .workspaceNotFound(id))
    }

    @Test
    func clientNotConnected() {
        let error = ToolError.clientNotConnected
        #expect(error.errorDomain == MonadErrorDomain.tool)
        #expect(error.errorCode == 206)
    }

    @Test
    func invalidArgument() {
        let error = ToolError.invalidArgument("count", expected: "Int", got: "String")
        #expect(error.errorDomain == MonadErrorDomain.tool)
        #expect(error.errorCode == 202)
        #expect(error == .invalidArgument("count", expected: "Int", got: "String"))
    }

    @Test
    func missingArgument() {
        let error = ToolError.missingArgument("query")
        #expect(error.errorDomain == MonadErrorDomain.tool)
        #expect(error.errorCode == 201)
        #expect(error == .missingArgument("query"))
    }

    @Test
    func executionFailed() {
        let error = ToolError.executionFailed("Timeout")
        #expect(error.errorDomain == MonadErrorDomain.tool)
        #expect(error.errorCode == 203)
        #expect(error == .executionFailed("Timeout"))
    }
}
