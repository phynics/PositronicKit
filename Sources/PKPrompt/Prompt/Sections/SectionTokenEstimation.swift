import Foundation

func estimatedTokenCount(for text: String) -> Int {
    text.isEmpty ? 0 : max(1, text.count / 4)
}
