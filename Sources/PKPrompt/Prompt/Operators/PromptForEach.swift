import Foundation
import PKShared

/// A transparent wrapper for repeated prompt content generated from a loop.
///
/// ``PromptBuilder`` lowers `for` loops into this composite so repeated authoring intent
/// remains explicit in the prompt tree before final resolution.
public struct PromptForEach<Content: PromptComposite>: PromptComposite {
    /// The repeated prompt content instances produced by the loop.
    public let content: [Content]
    private let iterationPathComponents: [String?]

    /// Creates a wrapper for repeated prompt content.
    ///
    /// - Parameter content: The prompt content instances produced by iteration.
    public init(_ content: [Content]) {
        self.content = content
        self.iterationPathComponents = Array(repeating: nil, count: content.count)
    }

    /// Creates repeated prompt content from identifiable data.
    ///
    /// - Parameters:
    ///   - data: The collection to iterate over.
    ///   - content: A builder that produces prompt content for each element.
    public init<Data>(
        _ data: Data,
        @PromptBuilder content: (Data.Element) -> Content
    ) where Data: Collection, Data.Element: Identifiable, Data.Element.ID: Hashable {
        self.content = data.map(content)
        self.iterationPathComponents = data.map { String(describing: $0.id) }
    }

    /// Creates repeated prompt content from data using an explicit stable identifier.
    ///
    /// - Parameters:
    ///   - data: The collection to iterate over.
    ///   - id: The key path to a unique identifier for each element.
    ///   - content: A builder that produces prompt content for each element.
    public init<Data, ID>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @PromptBuilder content: (Data.Element) -> Content
    ) where Data: Collection, ID: Hashable {
        self.content = data.map(content)
        self.iterationPathComponents = data.map { String(describing: $0[keyPath: id]) }
    }

    /// A placeholder body because this composite resolves through ``content`` directly.
    public var body: NeverSection {
        NeverSection()
    }

    /// Loop wrappers are transparent during path construction.
    public var sectionPathComponent: String? {
        nil
    }

    /// Resolves each repeated child in iteration order.
    ///
    /// - Parameter context: The resolution context to pass to each repeated child.
    /// - Returns: The concatenated resolved output of all repeated children.
    public func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection] {
        zip(content, iterationPathComponents).flatMap { child, pathComponent in
            child.resolve(in: context.descending(into: pathComponent))
        }
    }
}
