import Foundation

public enum PromptSectionValidationError: Error, Sendable, Equatable {
    case duplicateSectionIDs([String])
}

public func validateUniqueSectionIDs(_ sections: [ContextSection]) throws {
    let duplicates = duplicateSectionIDs(in: sections)
    guard duplicates.isEmpty else {
        throw PromptSectionValidationError.duplicateSectionIDs(duplicates)
    }
}

public func assertUniqueSectionIDs(_ sections: [ContextSection], context: String) {
    let duplicates = duplicateSectionIDs(in: sections)
    precondition(
        duplicates.isEmpty,
        "Duplicate context section ids in \(context): \(duplicates.joined(separator: ", "))"
    )
}

private func duplicateSectionIDs(in sections: [ContextSection]) -> [String] {
    var counts: [String: Int] = [:]
    for section in sections {
        counts[section.id, default: 0] += 1
    }
    return counts
        .filter { $0.value > 1 }
        .map(\.key)
        .sorted()
}
