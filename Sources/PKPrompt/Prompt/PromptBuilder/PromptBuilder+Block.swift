import Foundation

extension PromptBuilder {
    package struct Block<each Content: Prompt>: Prompt, PromptAssemblyNode {
        package let content: (repeat each Content)

        package init(_ content: repeat each Content) {
            self.content = (repeat each content)
        }

        package var body: EmptySection { EmptySection() }

        package func assembleSections(in context: PromptAssembly.Context) -> [AssembledPrompt.Section] {
            var resolvedSections: [AssembledPrompt.Section] = []
            repeat resolvedSections += PromptAssembly.resolve((each content), in: context)
            return resolvedSections
        }
    }
}
