import Testing
import Foundation
@testable import MonadShared

@Suite("Tool Parameters Extraction Tests")
struct ToolParametersTests {

    @Test("Require Parameter Success")
    func testRequireSuccess() throws {
        let params = ToolParameters(["path": "/tmp/test", "count": 42])

        let path = try params.require("path", as: String.self)
        #expect(path == "/tmp/test")

        let count = try params.require("count", as: Int.self)
        #expect(count == 42)
    }

    @Test("Require Missing Parameter Fails")
    func testRequireMissing() {
        let params = ToolParameters(["path": "/tmp/test"])

        #expect(throws: ToolError.self) {
            try params.require("count", as: Int.self)
        }
    }

    @Test("Require Invalid Type Fails")
    func testRequireInvalidType() {
        let params = ToolParameters(["count": "not an int"])

        #expect(throws: ToolError.self) {
            try params.require("count", as: Int.self)
        }
    }

    @Test("Optional Parameters")
    func testOptional() {
        let params = ToolParameters(["path": "/tmp/test"])

        #expect(params.optional("path", as: String.self) == "/tmp/test")
        #expect(params.optional("count", as: Int.self) == nil)
        #expect(params.optional("path", as: Int.self) == nil)
    }
}
