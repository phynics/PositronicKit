import Foundation

@resultBuilder
public enum PromptBuilder {
    public static func buildBlock(_ components: PromptGroup...) -> PromptGroup {
        PromptGroup(components.flatMap(\.sections))
    }

    public static func buildExpression<S: PromptComposite>(_ section: S) -> PromptGroup {
        PromptGroup([section])
    }

    public static func buildExpression(_ sections: [any PromptComposite]) -> PromptGroup {
        PromptGroup(sections)
    }

    public static func buildOptional(_ component: PromptGroup?) -> PromptGroup {
        component ?? PromptGroup()
    }

    public static func buildEither(first component: PromptGroup) -> PromptGroup {
        component
    }

    public static func buildEither(second component: PromptGroup) -> PromptGroup {
        component
    }

    public static func buildArray(_ components: [PromptGroup]) -> PromptGroup {
        PromptGroup(components.flatMap(\.sections))
    }

    public static func buildExpression(_: Void) -> PromptGroup {
        PromptGroup()
    }

    public static func buildFinalResult(_ component: PromptGroup) -> PromptGroup {
        component
    }
}
