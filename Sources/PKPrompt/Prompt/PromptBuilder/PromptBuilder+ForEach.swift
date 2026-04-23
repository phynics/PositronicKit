import Foundation

extension PromptBuilder {
    package struct ForEach<Content: Prompt>: Prompt, PromptNodeConvertible {
        package let content: [Content]
        package let iterationPathComponents: [String]

        package init(_ content: [Content]) {
            self.content = content
            self.iterationPathComponents = content.indices.map { "item_\($0)" }
        }

        package init<Data>(
            _ data: Data,
            @PromptBuilder content: (Data.Element) -> Content
        ) where Data: RandomAccessCollection {
            self.content = data.map(content)
            self.iterationPathComponents = data.indices.enumerated().map { offset, _ in "item_\(offset)" }
        }

        package init<Data, ID>(
            _ data: Data,
            id: KeyPath<Data.Element, ID>,
            @PromptBuilder content: (Data.Element) -> Content
        ) where Data: RandomAccessCollection, ID: CustomStringConvertible {
            self.content = data.map(content)
            self.iterationPathComponents = data.map { String(describing: $0[keyPath: id]) }
        }

        package var body: EmptySection { EmptySection() }

        package func makePromptNode() -> PromptNode? {
            let children: [PromptNode] = zip(content, iterationPathComponents).compactMap { child, pathComponent in
                guard let childNode = PromptAssembly.makeNode(from: child) else { return nil }
                return PromptNode.group(pathComponent: pathComponent, children: [childNode])
            }

            return children.isEmpty ? nil : PromptNode.group(children: children)
        }
    }
}
