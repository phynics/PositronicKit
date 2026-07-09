import Foundation
import PKShared

public enum MemorySavePolicy: Sendable {
    case immediate
    case deferred
    case deduplicating(threshold: Double)
}
