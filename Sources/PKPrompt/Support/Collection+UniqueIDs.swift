import Foundation
import PKShared
import PKUtilities

public extension Collection {
    func duplicateIDs<ID: Hashable & Comparable>(idKeyPath: KeyPath<Element, ID>) -> [ID] {
        var counts: [ID: Int] = [:]
        for element in self {
            counts[element[keyPath: idKeyPath], default: 0] += 1
        }

        return counts
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()
    }
}
