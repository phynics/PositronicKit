import Testing
import Foundation
@testable import PKShared

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

    @Test("Require Int from out-of-range Double throws instead of trapping")
    func testRequireIntFromOutOfRangeDouble() {
        let params = ToolParameters(["count": 1e30])

        #expect(throws: ToolError.self) {
            try params.require("count", as: Int.self)
        }
    }

    @Test("Require Int from NaN throws instead of trapping")
    func testRequireIntFromNaN() {
        let params = ToolParameters(["count": AnyCodable(Double.nan)])

        #expect(throws: ToolError.self) {
            try params.require("count", as: Int.self)
        }
    }

    @Test("Require Int from Infinity throws instead of trapping")
    func testRequireIntFromInfinity() {
        let params = ToolParameters(["count": AnyCodable(Double.infinity)])

        #expect(throws: ToolError.self) {
            try params.require("count", as: Int.self)
        }
    }

    @Test("Require Int from fractional Double throws (strict, no truncation)")
    func testRequireIntFromFractionalDouble() {
        let params = ToolParameters(["count": 4.7])

        #expect(throws: ToolError.self) {
            try params.require("count", as: Int.self)
        }
    }

    @Test("Require Int from integer-valued Double succeeds")
    func testRequireIntFromIntegerDouble() throws {
        let params = ToolParameters(["count": 4.0])

        let count = try params.require("count", as: Int.self)
        #expect(count == 4)
    }

    @Test("Optional Int from out-of-range Double returns nil instead of trapping")
    func testOptionalIntFromOutOfRangeDouble() {
        let params = ToolParameters(["count": 1e30])

        #expect(params.optional("count", as: Int.self) == nil)
    }

    @Test("Optional Int from NaN returns nil instead of trapping")
    func testOptionalIntFromNaN() {
        let params = ToolParameters(["count": AnyCodable(Double.nan)])

        #expect(params.optional("count", as: Int.self) == nil)
    }

    @Test("Optional Int from Infinity returns nil instead of trapping")
    func testOptionalIntFromInfinity() {
        let params = ToolParameters(["count": AnyCodable(Double.infinity)])

        #expect(params.optional("count", as: Int.self) == nil)
    }

    @Test("Optional Int from fractional Double returns nil (strict, no truncation)")
    func testOptionalIntFromFractionalDouble() {
        let params = ToolParameters(["count": 4.7])

        #expect(params.optional("count", as: Int.self) == nil)
    }

    @Test("Optional Int from integer-valued Double succeeds")
    func testOptionalIntFromIntegerDouble() {
        let params = ToolParameters(["count": 4.0])

        #expect(params.optional("count", as: Int.self) == 4)
    }
}
