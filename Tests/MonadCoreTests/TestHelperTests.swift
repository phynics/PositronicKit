import Testing
import Foundation
import Dependencies
@testable import MonadCore
@testable import MonadShared
@Suite("Test Helper Tests")
struct TestHelperTests {

    @Test("collect() helper captures all stream elements")
    func testCollectStream() async throws {
        let stream = AsyncStream<Int> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.yield(3)
            continuation.finish()
        }

        let collected = await stream.collect()
        #expect(collected == [1, 2, 3])
    }
}
