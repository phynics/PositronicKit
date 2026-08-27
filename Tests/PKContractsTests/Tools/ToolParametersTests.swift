import Testing
import Foundation
@testable import PKContracts

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

        do {
            _ = try params.require("count", as: Int.self)
            Issue.record("Should have thrown missingArgument")
        } catch ToolError.missingArgument("count") {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Require Invalid Type Fails")
    func testRequireInvalidType() {
        let params = ToolParameters(["count": "not an int"])

        do {
            _ = try params.require("count", as: Int.self)
            Issue.record("Should have thrown invalidArgument")
        } catch let ToolError.invalidArgument(key, expected, got) {
            #expect(key == "count")
            #expect(expected == "Int")
            #expect(got == "String")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Optional Parameters")
    func testOptional() {
        let params = ToolParameters(["path": "/tmp/test", "limit": 10])

        #expect(params.optional("path", as: String.self) == "/tmp/test")
        #expect(params.optional("count", as: Int.self) == nil)
        #expect(params.optional("path", as: Int.self) == nil)
        #expect(params.optional("missing", as: String.self) == nil)
        #expect(params.optional("limit", as: Int.self) == 10)
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

    @Test("Int extraction preserves exact 64-bit integer parameters")
    func intExtractionFromExactInteger() throws {
        let params = ToolParameters(["count": AnyCodable(Int64.max)])

        #expect(try params.require("count", as: Int.self) == Int.max)
        #expect(params.optional("count", as: Int.self) == Int.max)
    }

    @Test("Int extraction rejects out-of-range unsigned integers")
    func intExtractionRejectsOutOfRangeUnsignedInteger() {
        let params = ToolParameters(["count": AnyCodable(UInt64.max)])

        #expect(throws: ToolError.self) {
            try params.require("count", as: Int.self)
        }
        #expect(params.optional("count", as: Int.self) == nil)
    }

    @Test("Int extraction rejects potentially lossy large doubles")
    func intExtractionRejectsLossyLargeDouble() {
        let params = ToolParameters(["count": AnyCodable(9_007_199_254_740_992.0)])

        #expect(throws: ToolError.self) {
            try params.require("count", as: Int.self)
        }
        #expect(params.optional("count", as: Int.self) == nil)
    }

    @Test("Literal integer parameters convert exactly to floating types")
    func literalIntegerExtractionAsFloatingPoint() throws {
        let params = ToolParameters(["value": 42])

        #expect(try params.require("value", as: Double.self) == 42.0)
        #expect(params.optional("value", as: Double.self) == 42.0)
        #expect(try params.require("value", as: Float.self) == 42.0)
        #expect(params.optional("value", as: Float.self) == 42.0)
    }

    @Test("JSON integer parameters convert exactly to floating types")
    func decodedIntegerExtractionAsFloatingPoint() throws {
        let decoded = try JSONDecoder().decode(
            [String: AnyCodable].self,
            from: Data("{\"value\":42}".utf8)
        )
        let params = ToolParameters(decoded)

        #expect(try params.require("value", as: Double.self) == 42.0)
        #expect(params.optional("value", as: Double.self) == 42.0)
        #expect(try params.require("value", as: Float.self) == 42.0)
        #expect(params.optional("value", as: Float.self) == 42.0)
    }

    @Test("Floating extraction rejects integers that require rounding")
    func floatingExtractionRejectsUnrepresentableIntegers() {
        let binary64Loss = ToolParameters([
            "value": AnyCodable(Int64(9_007_199_254_740_993)),
        ])
        let binary32Loss = ToolParameters([
            "value": AnyCodable(Int64(16_777_217)),
        ])

        #expect(throws: ToolError.self) {
            try binary64Loss.require("value", as: Double.self)
        }
        #expect(binary64Loss.optional("value", as: Double.self) == nil)
        #expect(throws: ToolError.self) {
            try binary32Loss.require("value", as: Float.self)
        }
        #expect(binary32Loss.optional("value", as: Float.self) == nil)
    }
}
