---
status: accepted
---

# Prompt DSL keeps SwiftUI-shaped names

Issue #156 audited the public surface for names that collide with platform types and required a
recorded decision for `PKPrompt.ForEach`, which collides with `SwiftUI.ForEach`. The decision is to
keep the name. `PKPrompt` structural types that mirror a SwiftUI construct use the SwiftUI
spelling, and the runtime ships no second spelling for them.

PromptBuilder is a result builder whose authored syntax deliberately reads like SwiftUI. The
resemblance is the feature: a caller who knows `ForEach(items) { item in ... }` in a view body can
compose a prompt section without learning a parallel vocabulary. A `PromptForEach` or `PKForEach`
spelling would preserve the shape while discarding the recognition that makes the shape worth
having, and it would sit inconsistently beside `PromptTuple`, `PromptArray`, `OptionalPrompt`, and
`EitherPrompt`, which describe structure rather than mirror a SwiftUI name.

Inside a `@PromptBuilder` closure the collision does not arise. The builder's input types admit
only `Prompt` content, so an unqualified `ForEach` resolves to `PKPrompt.ForEach` even when the
file also imports SwiftUI. This is the call site the DSL is written for.

Outside a result-builder context the collision is real and this decision does not remove it. A file
that imports both SwiftUI and PKPrompt and names `ForEach` in an ordinary expression must write
`PKPrompt.ForEach`. That cost is accepted: the qualified spelling is a normal Swift disambiguation
at an uncommon call site, not the repeated selective-type-import workaround that motivated the
Timeline rename, and it never appears in the authored-prompt syntax the DSL exists to provide.
`Tests/PublicProductConsumer/CollisionConsumer.swift` compiles both call sites so neither claim
depends on prose.

This narrows the naming rule in [ADR 0008](0008-timeline-naming-hard-cut.md) rather than
contradicting it. The `PK` prefix remains reserved for names that need disambiguation in ordinary
imports, which is why the facade is `PKRuntime` and the executable contract is `PKTool`. A name
that is reached through a result builder is not resolved by ordinary import lookup, so the prefix
rule does not reach it. `TimelineRecord` and every other durable-history name are unaffected.

No compatibility alias, second spelling, or `PromptForEach` shim is introduced, consistent with
#156 and ADR 0008. Documentation describes exactly one way to write each construct.
