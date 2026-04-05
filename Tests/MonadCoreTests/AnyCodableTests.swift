import Foundation
import Testing
@testable import MonadCore
@testable import MonadShared
@Suite struct AnyCodableTests {

    @Test("Test string description")
    func testDescription() {
        let ac = AnyCodable("hello")
        #expect(ac.description == "hello")

        let acInt = AnyCodable(123)
        #expect(acInt.description == "123.0")
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
}
