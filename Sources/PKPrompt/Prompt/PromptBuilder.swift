import Foundation

/// Result builder for authoring declarative prompt trees.
///
/// The builder lowers authored control flow into semantic composites such as
/// ``PromptBuilder/Conditional``, ``PromptBuilder/ForEach``, and ``PromptBuilder/Optional`` while preserving the
/// concrete authored composite types wherever possible.
///
/// ```swift
/// let prompt = AnyPrompt.build {
///     SystemPrompt("You are helpful.")
///
///     if includeHistory {
///         AnyPrompt.build {
///             HistoryPrompt(messages)
///         }
///     }
///
///     for item in items {
///         UserPrompt(item)
///     }
/// }
/// ```
@resultBuilder
public enum PromptBuilder {
    /// Wraps authored siblings in a typed block.
    public static func buildBlock<Content: Prompt>(_ content: Content) -> Content {
        content
    }

    /// Wraps authored siblings in a typed block.
    public static func buildBlock<each Content: Prompt>(
        _ content: repeat each Content
    ) -> some Prompt {
        Block(repeat each content)
    }
    
    /// Preserves a single prompt composite expression without extra wrapping.
    public static func buildExpression<S: Prompt>(_ section: S) -> S {
        section
    }

    /// Wraps an explicit list of prompt composites for further builder composition.
    public static func buildExpression(_ sections: [any Prompt]) -> AnyPrompt {
        AnyPrompt(sections)
    }

    /// Lowers an optional branch into ``PromptBuilder/Optional``.
    public static func buildOptional<Content: Prompt>(
        _ component: Content?
    ) -> some Prompt {
        // Preserve the authored optional node even when the branch resolves to nil so
        // downstream prompt introspection can still see that an optional boundary existed.
        Optional<Content, EmptySection>(primary: component)
    }

    /// Lowers the selected `if` branch into ``PromptBuilder/Conditional``.
    public static func buildEither<TrueContent: Prompt, FalseContent: Prompt>(
        first component: TrueContent
    ) -> some Prompt {
        Conditional<TrueContent, FalseContent>(first: component)
    }

    /// Lowers the selected `else` branch into ``PromptBuilder/Conditional``.
    public static func buildEither<TrueContent: Prompt, FalseContent: Prompt>(
        second component: FalseContent
    ) -> some Prompt {
        Conditional<TrueContent, FalseContent>(second: component)
    }

    /// Lowers repeated builder output into ``PromptBuilder/ForEach``.
    public static func buildArray<Content: Prompt>(_ components: [Content]) -> some Prompt {
        // Keep the loop as a first-class composite instead of flattening immediately so
        // later phases can distinguish authored repetition from ordinary sibling sections.
        ForEach(components)
    }

    /// Ignores expressions that produce no prompt content.
    public static func buildExpression(_: Void) -> EmptySection {
        EmptySection()
    }

    /// Returns the fully lowered root prompt content.
    public static func buildFinalResult<Content: Prompt>(_ component: Content) -> Content {
        component
    }
}

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
