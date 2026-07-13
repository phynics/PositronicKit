import Foundation
import Testing
@testable import PKPrompt
@testable import PKShared
import PKUtilities

@Suite("HistoryPromptPrimitive")
struct HistoryPromptPrimitiveTests {
    @Test("History token estimates use shared token estimator")
    func estimatedTokensUseSharedEstimator() {
        let primitive = HistoryPromptPrimitive(messages: [
            Message(content: "你好世界", role: .user)
        ])

        #expect(primitive.estimatedTokens == 4)
    }
}
