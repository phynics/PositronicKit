import Foundation

/// Prompt-side convenience spelling for ``PromptForEach``.
///
/// This allows prompt builders to use `ForEach(data) { ... }` naturally while still lowering to
/// the same stable-identity prompt loop implementation as ``PromptForEach``.
public typealias ForEach<Content: Prompt> = PromptForEach<Content>
