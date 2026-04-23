import Foundation

extension PromptBuilder {
    package struct ForEach<Content: Prompt>: Prompt, PromptAssemblyNode {
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

        package func assembleSections(in context: PromptAssembly.Context) -> [AssembledPrompt.Section] {
            zip(content, iterationPathComponents).flatMap { child, pathComponent in
                PromptAssembly.resolve(child, in: context.descending(into: pathComponent))
            }
        }
    }
}
