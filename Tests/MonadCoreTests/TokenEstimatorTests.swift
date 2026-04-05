import MonadCore
import Testing

@Suite struct TokenEstimatorTests {

    @Test("Test empty string estimation")
    func emptyString() {
        #expect(TokenEstimator.estimate(text: "") == 0)
    }

    @Test("Test basic english estimation")
    func basicEnglish() {
        // "Hello world" -> 2 words * 1.33 = 2.66 -> 2
        let count = TokenEstimator.estimate(text: "Hello world")
        #expect(count >= 2)
    }

    @Test("Test multi-byte character estimation")
    func multiByteCharacters() {
        // "Monad Assistant 🚀" -> 2 words + emoji (which NL might not count as word, or treat separately)
        let count = TokenEstimator.estimate(text: "Monad Assistant 🚀")
        #expect(count >= 2)
    }

    @Test("Test large input estimation")
    func largeInput() {
        // 1000 words -> ~1330 tokens
        let largeString = String(repeating: "word ", count: 1000)
        let count = TokenEstimator.estimate(text: largeString)
        // Check range to allow for heuristic variance
        #expect(count > 1000 && count < 1500)
    }
}
