import Testing
@testable import PKShared

@Suite("TokenEstimator")
struct TokenEstimatorTests {
    @Test("Empty text estimates to zero tokens")
    func emptyText() {
        #expect(TokenEstimator.estimate(text: "") == 0)
    }

    @Test("Punctuation contributes to token estimates")
    func punctuation() {
        #expect(TokenEstimator.estimate(text: "Hello, world!") == 4)
    }

    @Test("Numeric runs are treated as a single token")
    func numericRun() {
        #expect(TokenEstimator.estimate(text: "2026") == 1)
    }

    @Test("CJK text counts by visible characters")
    func cjkCharacters() {
        #expect(TokenEstimator.estimate(text: "你好世界") == 4)
    }

    @Test("Part estimates use shared joined-text behavior")
    func parts() {
        #expect(TokenEstimator.estimate(parts: ["Hello", "world"]) == 2)
    }
}
