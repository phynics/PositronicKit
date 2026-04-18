import Foundation

/// Ergonomic alias for ``PromptGroup`` when authoring declarative prompt trees.
///
/// Use `Group` inside ``PromptBuilder`` closures when you want to make a nested grouping
/// explicit without introducing a domain-specific composite type.
public typealias Group = PromptGroup
