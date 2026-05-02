import Foundation

package extension Prompt {
    func resolveSections(in context: PromptBuildContext) -> [PromptSection] {
        makePromptNode()?.resolve(in: context) ?? []
    }
}

public extension Prompt {
    func resolveSections() -> [PromptSection] {
        resolveSections(in: PromptBuildContext())
    }
}
