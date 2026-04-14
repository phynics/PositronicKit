import Foundation

public enum PromptSectionValidationError: Error, Sendable, Equatable {
    case duplicateSectionIDs([String])
}

public func validateUniqueSectionIDs(_ sections: [any ContextSection]) throws {
    try validateUniqueSectionIDs(sections.flatMap { $0.resolve(in: ContextSectionResolutionContext()) })
}

public func validateUniqueSectionIDs(_ sections: [ResolvedContextSection]) throws {
    let duplicates = duplicateSectionIDs(in: sections)
    guard duplicates.isEmpty else {
        throw PromptSectionValidationError.duplicateSectionIDs(duplicates)
    }
}

public func assertUniqueSectionIDs(_ sections: [any ContextSection], context: String) {
    let duplicates = duplicateSectionIDs(in: sections.flatMap { $0.resolve(in: ContextSectionResolutionContext()) })
    precondition(
        duplicates.isEmpty,
        "Duplicate context section ids in \(context): \(duplicates.joined(separator: ", "))"
    )
}

public func assertUniqueSectionIDs(_ sections: [ResolvedContextSection], context: String) {
    let duplicates = duplicateSectionIDs(in: sections)
    precondition(
        duplicates.isEmpty,
        "Duplicate context section ids in \(context): \(duplicates.joined(separator: ", "))"
    )
}

func duplicateSectionIDs(in sections: [ResolvedContextSection]) -> [String] {
    var counts: [String: Int] = [:]
    for section in sections {
        counts[section.id, default: 0] += 1
    }
    return counts
        .filter { $0.value > 1 }
        .map(\.key)
        .sorted()
}
