import Foundation

extension PromptBuilder {
    package struct Block<each Content: Prompt>: Prompt, PromptNodeConvertible {
        package let content: (repeat each Content)

        package init(_ content: repeat each Content) {
            self.content = (repeat each content)
        }

        package var body: EmptySection { EmptySection() }

        package func makePromptNode() -> PromptNode? {
            var nodes: [PromptNode] = []
            for node in repeat PromptAssembly.makeNode(from: each content) {
                if let node {
                    nodes.append(node)
                }
            }
            return nodes.isEmpty ? nil : PromptNode.group(children: nodes)
        }
    }
}
