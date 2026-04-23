import Foundation

extension PromptBuilder {
    package struct Conditional<First: Prompt, Second: Prompt>: Prompt, PromptNodeConvertible {
        package enum Storage: Sendable {
            case first(First)
            case second(Second)
        }

        package let storage: Storage

        package init(first content: First) { self.storage = .first(content) }
        package init(second content: Second) { self.storage = .second(content) }

        package var body: EmptySection { EmptySection() }

        package func makePromptNode() -> PromptNode? {
            switch storage {
            case let .first(content):
                return PromptAssembly.makeNode(from: content)
            case let .second(content):
                return PromptAssembly.makeNode(from: content)
            }
        }
    }
}
