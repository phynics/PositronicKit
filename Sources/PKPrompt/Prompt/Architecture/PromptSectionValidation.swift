import Foundation

public enum PromptSectionValidationError: Error, Sendable, Equatable {
    case duplicateSectionIDs([String])
    case multipleUserQuerySections([String])
}

public enum PromptSectionValidator {
    public static func validateUniqueIDs(in sections: [any PromptComposite]) throws {
        try validateUniqueIDs(in: sections.flatMap { $0.resolve(in: PromptResolutionContext()) })
    }

    public static func validateUniqueIDs(in sections: [ResolvedPromptSection]) throws {
        do {
            try sections.assertUniqueIDs(idKeyPath: \.id)
        } catch let CollectionUniqueIDError.duplicateIDs(duplicates) {
            throw PromptSectionValidationError.duplicateSectionIDs(duplicates)
        }
    }

    public static func assertUniqueIDs(in sections: [any PromptComposite], context: String) {
        let duplicates = duplicateIDs(in: sections.flatMap { $0.resolve(in: PromptResolutionContext()) })
        precondition(
            duplicates.isEmpty,
            "Duplicate context section ids in \(context): \(duplicates.joined(separator: ", "))"
        )
    }

    public static func assertUniqueIDs(in sections: [ResolvedPromptSection], context: String) {
        let duplicates = duplicateIDs(in: sections)
        precondition(
            duplicates.isEmpty,
            "Duplicate context section ids in \(context): \(duplicates.joined(separator: ", "))"
        )
    }

    static func duplicateIDs(in sections: [ResolvedPromptSection]) -> [String] {
        sections.duplicateIDs(idKeyPath: \.id)
    }
}
