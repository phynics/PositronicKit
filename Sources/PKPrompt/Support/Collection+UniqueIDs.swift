import Foundation

public enum CollectionUniqueIDError: Error, Sendable, Equatable {
    case duplicateIDs([String])
}

extension Collection where Element: Identifiable, Element.ID: Hashable & Comparable {
    func assertUniqueIDs() throws {
        try assertUniqueIDs(idKeyPath: \.id)
    }
}

extension Collection {
    func assertUniqueIDs<ID: Hashable & Comparable>(idKeyPath: KeyPath<Element, ID>) throws {
        let duplicates = duplicateIDs(idKeyPath: idKeyPath)
        guard duplicates.isEmpty else {
            throw CollectionUniqueIDError.duplicateIDs(duplicates.map { String(describing: $0) })
        }
    }

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
