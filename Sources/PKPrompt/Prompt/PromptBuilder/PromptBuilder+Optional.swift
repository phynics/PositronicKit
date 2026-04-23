import Foundation

extension PromptBuilder {
    package struct Optional<Primary: Prompt, Fallback: Prompt>: Prompt, PromptAssemblyNode {
        package let primary: Primary?
        package let fallback: Fallback?

        package init(primary: Primary?, fallback: Fallback? = nil) {
            self.primary = primary
            self.fallback = fallback
        }

        package var body: EmptySection { EmptySection() }

        package func assembleSections(in context: PromptAssembly.Context) -> [AssembledPrompt.Section] {
            if let primary {
                return PromptAssembly.resolve(primary, in: context)
            }
            return fallback.map { PromptAssembly.resolve($0, in: context) } ?? []
        }
    }
}
