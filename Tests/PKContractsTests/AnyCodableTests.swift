import Foundation
import Testing
@testable import PKContracts
@Suite struct AnyCodableTests {

    @Test("Test string description")
    func testDescription() {
        let ac = AnyCodable("hello")
        #expect(ac.description == "hello")

        let acInt = AnyCodable(123)
        #expect(acInt.description == "123")
    }

    @Test("Test encoding and decoding primitive types")
    func testEncodingDecodingPrimitives() throws {
        let values: [Any] = ["string", 42, 3.14, true]

        for value in values {
            let ac = AnyCodable(value)
            let data = try JSONEncoder().encode(ac)
            let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
            #expect(ac == decoded)
        }
    }

    @Test("Test encoding and decoding nested structures")
    func testNestedStructures() throws {
        let nested: [String: Any] = [
            "arr": [1, 2, "3"],
            "dict": ["key": "val"],
            "null": NSNull()
        ]

        let ac = AnyCodable(nested)
        let data = try JSONEncoder().encode(ac)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)

        #expect(ac == decoded)

        // Verify specifically that we didn't double wrap
        let decodedDict = decoded.value as? [String: Any]
        #expect(decodedDict?["arr"] is [Any])
        #expect(!(decodedDict?["arr"] is [AnyCodable])) // Decoded values are unwrapped
    }

    @Test("Test encoding double wrapped AnyCodable")
    func testDoubleWrappingPrevention() throws {
        let inner = AnyCodable("inner")
        let outer = AnyCodable(inner)

        let data = try JSONEncoder().encode(outer)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "\"inner\"") // Should not be nested JSON

        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.value as? String == "inner")
    }

    @Test("Signed 64-bit JSON integers round-trip without precision loss")
    func signedIntegerPrecision() throws {
        let values: [Int64] = [
            9_007_199_254_740_991,
            9_007_199_254_740_992,
            9_007_199_254_740_993,
            .max,
        ]

        for value in values {
            let original = AnyCodable(value)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)

            #expect(original == .integer(value))
            #expect(decoded == .integer(value))
            #expect(decoded.value as? Int64 == value)
        }
    }

    @Test("Unsigned 64-bit JSON integers round-trip without precision loss")
    func unsignedIntegerPrecision() throws {
        let signedRangeValue = UInt64(9_007_199_254_740_993)
        let signedRangeDecoded = try JSONDecoder().decode(
            AnyCodable.self,
            from: JSONEncoder().encode(AnyCodable(signedRangeValue))
        )
        let unsignedOnlyDecoded = try JSONDecoder().decode(
            AnyCodable.self,
            from: JSONEncoder().encode(AnyCodable(UInt64.max))
        )

        #expect(AnyCodable(signedRangeValue) == .unsignedInteger(signedRangeValue))
        // JSON has no signedness marker, so values within Int64's range decode as signed.
        #expect(signedRangeDecoded == .integer(Int64(signedRangeValue)))
        #expect(unsignedOnlyDecoded == .unsignedInteger(.max))
        #expect(unsignedOnlyDecoded.value as? UInt64 == .max)
    }

    @Test("JSON decoding retains integral and floating number representations")
    func jsonNumberRepresentations() throws {
        let integer = try JSONDecoder().decode(AnyCodable.self, from: Data("9007199254740993".utf8))
        let floating = try JSONDecoder().decode(AnyCodable.self, from: Data("3.14".utf8))

        #expect(integer == .integer(9_007_199_254_740_993))
        #expect(floating == .number(3.14))
    }

    @Test("JSON utility renders exact integral values")
    func jsonUtilityPreservesIntegerPrecision() throws {
        let json = try toJsonString([
            "signed": AnyCodable(Int64.max),
            "unsigned": AnyCodable(UInt64.max),
        ])

        #expect(json == "{\"signed\":9223372036854775807,\"unsigned\":18446744073709551615}")
    }
}
