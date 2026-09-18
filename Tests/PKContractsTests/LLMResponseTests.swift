import Testing
@testable import PKContracts
import Foundation

@Suite final class LLMResponseTests {
    private func assertCodable<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(value == decoded)
    }

    @Test

    func testLLMResponseCodable() throws {
        let metadata = LLMResponse(
            content: "answer",
            id: "response-1",
            model: "claude-3-opus",
            usage: LLMTokenUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150),
            duration: 2.5,
            tokensPerSecond: 45.2
        )
        try assertCodable(metadata)
    }

    @Test

    func testLLMResponseWithNilUsage() throws {
        let metadata = LLMResponse(
            model: "gpt-4",
            duration: 1.0,
            tokensPerSecond: 20.0
        )
        try assertCodable(metadata)
    }

    @Test

    func testLLMResponsePerformanceCalc() {
        let metadata = LLMResponse(model: "test", duration: 1.5, tokensPerSecond: 100)
        #expect(metadata.duration == 1.5)
        #expect(metadata.tokensPerSecond == 100)
    }
}
