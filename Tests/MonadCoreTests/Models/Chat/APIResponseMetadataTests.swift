import Testing
@testable import MonadCore
@testable import MonadShared
import Foundation

@Suite final class APIResponseMetadataTests {
    private func assertCodable<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(value == decoded)
    }

    @Test

    func testAPIResponseMetadataCodable() throws {
        let metadata = APIResponseMetadata(
            model: "claude-3-opus",
            promptTokens: 100,
            completionTokens: 50,
            totalTokens: 150,
            duration: 2.5,
            tokensPerSecond: 45.2
        )
        try assertCodable(metadata)
    }

    @Test

    func testAPIResponseMetadataWithNilTokens() throws {
        let metadata = APIResponseMetadata(
            model: "gpt-4",
            promptTokens: Optional<Int>.none,
            completionTokens: Optional<Int>.none,
            totalTokens: Optional<Int>.none,
            duration: 1.0,
            tokensPerSecond: 20.0
        )
        try assertCodable(metadata)
    }

    @Test

    func testAPIResponseMetadataPerformanceCalc() {
        let metadata = APIResponseMetadata(model: "test", duration: 1.5, tokensPerSecond: 100)
        #expect(metadata.duration == 1.5)
        #expect(metadata.tokensPerSecond == 100)
    }
}
