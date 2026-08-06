# PKAPI-009 — `formatToolsForPrompt(_:)` should be a method/property on `[AnyTool]`, not a free function

**Priority:** P3
**Type:** API design / naming
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, commit `cb3df9d`, merged into `main`) — converted to
`extension [AnyTool] { func formattedForPrompt() async -> String }`. Stays `async` (awaits
`Tool.canExecute()` per tool). All in-repo call sites updated. Downstream grep clean — no consumer
calls the free function directly. `swift test` green (932 tests / 159 suites). CHANGELOG updated
(Breaking, low external impact per grep).

### Summary

Confirmed: `public func formatToolsForPrompt(_ tools: [AnyTool]) async -> String`
(`Sources/PKShared/Tools/Tool.swift:154`) is a free function with an obvious receiver —
the `[AnyTool]` array — and is side-effect-free (formatting, not an action), which per
Swift API conventions should read as a noun phrase / extension member rather than an
imperative-verb free function.

### Implementation Requirements

- [ ] Convert to `extension [AnyTool] { func formattedForPrompt() async -> String }` (or
      `var promptFormatted: String` if it can be made synchronous — check why it's
      currently `async`, likely because `Tool.summarize`/schema formatting await
      something internally; if so keep it a method, not a property, since Swift
      properties shouldn't be `async` unless idiomatic for the codebase already).
- [ ] Update all call sites (prompt assembly / `PromptSectionProviding` implementations
      that currently call `formatToolsForPrompt(tools)`).

### Acceptance Criteria

- [ ] Free function replaced with an extension member on `[AnyTool]`; call sites updated.
- [ ] `make verify` green; CHANGELOG updated (breaking rename, but low external impact —
      grep downstream to confirm no consumer calls the free function directly).
