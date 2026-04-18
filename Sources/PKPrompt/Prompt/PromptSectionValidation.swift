import Foundation

public enum PromptSectionValidationError: Error, Sendable, Equatable {
    case duplicateSectionIDs([String])
}

public func validateUniqueSectionIDs(_ sections: [any PromptComposite]) throws {
    try validateUniqueSectionIDs(sections.flatMap { $0.resolve(in: PromptResolutionContext()) })
}

public func validateUniqueSectionIDs(_ sections: [ResolvedPromptSection]) throws {
    let duplicates = duplicateSectionIDs(in: sections)
    guard duplicates.isEmpty else {
        throw PromptSectionValidationError.duplicateSectionIDs(duplicates)
    }
}

public func assertUniqueSectionIDs(_ sections: [any PromptComposite], context: String) {
    let duplicates = duplicateSectionIDs(in: sections.flatMap { $0.resolve(in: PromptResolutionContext()) })
    precondition(
        duplicates.isEmpty,
        "Duplicate context section ids in \(context): \(duplicates.joined(separator: ", "))"
    )
}

public func assertUniqueSectionIDs(_ sections: [ResolvedPromptSection], context: String) {
    let duplicates = duplicateSectionIDs(in: sections)
    precondition(
        duplicates.isEmpty,
        "Duplicate context section ids in \(context): \(duplicates.joined(separator: ", "))"
    )
}

func duplicateSectionIDs(in sections: [ResolvedPromptSection]) -> [String] {
    var counts: [String: Int] = [:]
    for section in sections {
        counts[section.id, default: 0] += 1
    }
    return counts
        .filter { $0.value > 1 }
        .map(\.key)
        .sorted()
}
