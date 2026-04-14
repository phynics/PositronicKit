import Foundation

@resultBuilder
public enum ContextBuilder {
    public static func buildBlock(_ components: SectionGroup...) -> SectionGroup {
        SectionGroup(components.flatMap(\.sections))
    }

    public static func buildExpression<S: ContextSection>(_ section: S) -> SectionGroup {
        SectionGroup([section])
    }

    public static func buildExpression(_ sections: [any ContextSection]) -> SectionGroup {
        SectionGroup(sections)
    }

    public static func buildOptional(_ component: SectionGroup?) -> SectionGroup {
        component ?? SectionGroup()
    }

    public static func buildEither(first component: SectionGroup) -> SectionGroup {
        component
    }

    public static func buildEither(second component: SectionGroup) -> SectionGroup {
        component
    }

    public static func buildArray(_ components: [SectionGroup]) -> SectionGroup {
        SectionGroup(components.flatMap(\.sections))
    }

    public static func buildExpression(_: Void) -> SectionGroup {
        SectionGroup()
    }

    public static func buildFinalResult(_ component: SectionGroup) -> SectionGroup {
        component
    }
}
