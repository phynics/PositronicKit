import Foundation

/// A result builder for composing prompt context sections declaratively
@resultBuilder
public enum ContextBuilder {
    public static func buildBlock(_ sections: [ContextSection]...) -> [ContextSection] {
        sections.flatMap { $0 }
    }

    public static func buildExpression(_ section: ContextSection) -> [ContextSection] {
        [section]
    }

    public static func buildExpression(_ sections: [ContextSection]) -> [ContextSection] {
        sections
    }

    public static func buildOptional(_ component: [ContextSection]?) -> [ContextSection] {
        component ?? []
    }

    public static func buildEither(first component: [ContextSection]) -> [ContextSection] {
        component
    }

    public static func buildEither(second component: [ContextSection]) -> [ContextSection] {
        component
    }

    public static func buildArray(_ components: [[ContextSection]]) -> [ContextSection] {
        components.flatMap { $0 }
    }

    /// Support for void/empty expressions (e.g. print statements in builder)
    public static func buildExpression(_: Void) -> [ContextSection] {
        []
    }
}
