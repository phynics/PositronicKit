import Foundation

public extension Array where Element == PromptSection {
    /// Estimated token count across all prompt sections in their current order.
    var estimatedTokens: Int {
        reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Validates prompt shape and returns sections in canonical assembly order.
    ///
    /// Sections are sorted by cache policy, then priority, while preserving source order as a
    /// final tiebreaker.
    func validatedAndSorted() throws -> [PromptSection] {
        let duplicateIDs = duplicateIDs(idKeyPath: \.id)
        guard duplicateIDs.isEmpty else {
            throw PromptAssemblyError.duplicateSectionIDs(duplicateIDs)
        }

        let userQueryIDs = filter { $0.role == .userQuery }
            .map(\.id)
            .sorted()
        guard userQueryIDs.count <= 1 else {
            throw PromptAssemblyError.multipleUserQuerySections(userQueryIDs)
        }

        return enumerated().sorted { lhs, rhs in
            if lhs.element.cachePolicy != rhs.element.cachePolicy {
                return lhs.element.cachePolicy < rhs.element.cachePolicy
            }
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority > rhs.element.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
