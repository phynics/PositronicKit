import Testing
@testable import PKShared
import PKUtilities

@Suite("StableHash")
struct StableHashTests {
    @Test("Produces deterministic output for same input")
    func deterministicForSameInput() {
        let first = StableHash.hash("same-input")
        let second = StableHash.hash("same-input")
        #expect(first == second)
    }

    @Test("Separates component boundaries")
    func separatesComponentBoundaries() {
        let compact = StableHash.hash(components: ["ab", "c"])
        let merged = StableHash.hash(components: ["a", "bc"])
        #expect(compact != merged)
    }
}
