import Foundation

extension PromptBuilder {
    package struct Optional<Primary: Prompt, Fallback: Prompt>: Prompt, PromptNodeConvertible {
        package let primary: Primary?
        package let fallback: Fallback?

        package init(primary: Primary?, fallback: Fallback? = nil) {
            self.primary = primary
            self.fallback = fallback
        }

        package var body: EmptySection { EmptySection() }

        package func makePromptNode() -> PromptNode? {
            if let primary {
                return PromptAssembly.makeNode(from: primary)
            }
            return fallback.flatMap { PromptAssembly.makeNode(from: $0) }
        }
    }
}
