@testable import PKContracts
import PKUtilities
import Testing

@Suite("LogRedaction")
struct LogRedactionTests {
    @Test("redactedHash produces 8-char hex string")
    func hashFormat() {
        let result = redactedHash("hello")
        #expect(result.count == 8)
        #expect(result.allSatisfy { $0.isHexDigit })
    }

    @Test("same input gives same hash")
    func hashStability() {
        #expect(redactedHash("test") == redactedHash("test"))
    }

    @Test("different inputs give different hashes")
    func hashDifferentiation() {
        #expect(redactedHash("abc") != redactedHash("xyz"))
    }
}
