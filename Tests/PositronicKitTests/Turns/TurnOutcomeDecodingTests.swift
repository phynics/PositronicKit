import Foundation
@testable import PositronicKit
import Testing

@Suite("Turn outcome decoding", .tags(.unit))
struct TurnOutcomeDecodingTests {
    @Test("an unknown stored outcome kind is rejected")
    func unknownStoredKindIsRejected() {
        let data = Data(#"{"kind":"limitReached","reason":"toolDispatches"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TurnOutcome.self, from: data)
        }
    }
}
