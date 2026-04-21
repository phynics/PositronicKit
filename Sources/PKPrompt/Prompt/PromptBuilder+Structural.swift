//
//  PromptBuilder+Structural.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 21.04.26.
//


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
