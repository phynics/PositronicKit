# PKR-7 — `ForEach`/`buildArray` documented "positional path groups" don't exist

**Status:** Done
**Severity:** 🟠 Medium (doc/code drift + latent ID-collision footgun)
**Repos:** PositronicKit (PKPrompt)
**Source:** PositronicKit review 2026-07-02

## Problem

Docs promise positional disambiguation that the implementation never does:

- `Sources/PKPrompt/PromptBuilder/Structural/ForEach.swift:5-6` claims loops "lower to positional
  path components such as `item_0` and `item_1`"; `PromptBuilder.swift:78` documents `buildArray`
  as "positional per-item path groups".
- `ForEach.makePromptNode()` (`ForEach.swift:25-35`) attaches no index/position to child
  `pathComponent`s — nothing positional is ever added.
- Doc comments reference `PromptForEach` and `forEach(_:id:content:)` — neither symbol exists
  anywhere in Sources or Tests (grep-verified): dead/aspirational API references.
- The only loop test (`PromptBuilderTests.swift:65-78`) uses distinct explicit ids, so the gap is
  unexercised. Two loop-generated sections with colliding ids throw
  `PromptAssemblyError.duplicateSectionIDs` (then get swallowed by PKR-6's `try?` in
  `renderToString`) despite the documented fallback.

## Suggested direction

Either implement positional path components in `ForEach.makePromptNode()` or fix the docs to state
loop-item uniqueness is the caller's responsibility, and remove the phantom API references. Add a
test with colliding loop-item ids pinning whichever behavior is chosen.

## Resolution (2026-07-04)

Chose the doc-fix path: positional path disambiguation is a feature addition with broader
implications (path-component threading through the node tree, journal-diff impact), and the
existing design already expects callers to provide unique ids.

- `ForEach.swift` doc comment: removed the "plain `for` loops lower to positional path components
  such as `item_0` and `item_1`" claim and the `PromptForEach` reference. Now states that
  `ForEach` does not attach positional path components, loop-item uniqueness is the caller's
  responsibility, and colliding ids raise `duplicateSectionIDs`.
- `PromptBuilder.swift` doc comment: removed the `PromptForEach` and
  `PromptBuilder/forEach(_:id:content:)` references (neither symbol exists). Now states that
  plain `for` loops produce a `ForEach` whose children carry their own section ids, with no
  positional disambiguation.
- `buildArray` doc comment: changed from "positional per-item path groups" to "a `ForEach` whose
  children carry their own section ids."

Added two tests pinning the colliding-id behavior:
- `loopCollidingIdsRaise` — `for item in items` with two items resolving to the same section id →
  `AssembledPrompt.ValidationError.duplicateSectionIDs`.
- `forEachCollidingIdsRaise` — `ForEach(data:)` with colliding ids → same error.

688 PositronicKit tests green.
