import Foundation
import PKTestSupport
import Testing

@Suite("MockEmbeddingService")
struct MockEmbeddingServiceTests {
    @Test("concurrent embedding calls return valid vectors and capture a submitted input")
    func concurrentEmbeddingCallsReturnValidVectorsAndCaptureSubmittedInput() async throws {
        let service = MockEmbeddingService()
        service.useDistinctEmbeddings = true
        let inputs = (0 ..< 100).map { "embedding-input-\($0)" }

        let results = try await withThrowingTaskGroup(
            of: (input: String, vector: [Float]).self,
            returning: [(input: String, vector: [Float])].self
        ) { group in
            for input in inputs {
                group.addTask {
                    (input, try await service.generateEmbedding(for: input))
                }
            }

            var results: [(input: String, vector: [Float])] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        #expect(results.count == inputs.count)
        #expect(results.allSatisfy { result in
            guard result.vector.count == 16, result.vector.allSatisfy(\.isFinite) else {
                return false
            }
            let magnitude = sqrt(result.vector.reduce(0) { $0 + $1 * $1 })
            return abs(magnitude - 1) < 0.0001
        })
        #expect(service.lastInput.map(Set(inputs).contains) == true)
    }
}
