import Foundation

extension PromptBuilder {
    package struct Conditional<First: Prompt, Second: Prompt>: Prompt, PromptAssemblyNode {
        package enum Storage: Sendable {
            case first(First)
            case second(Second)
        }

        package let storage: Storage

        package init(first content: First) { self.storage = .first(content) }
        package init(second content: Second) { self.storage = .second(content) }

        package var body: EmptySection { EmptySection() }

        package func assembleSections(in context: PromptAssembly.Context) -> [AssembledPrompt.Section] {
            switch storage {
            case let .first(content):
                return PromptAssembly.resolve(content, in: context)
            case let .second(content):
                return PromptAssembly.resolve(content, in: context)
            }
        }
    }
}
