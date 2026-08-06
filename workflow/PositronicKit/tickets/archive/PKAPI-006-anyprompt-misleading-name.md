# PKAPI-006 — `AnyPrompt` name suggests type erasure but is a container/group

**Priority:** P3
**Type:** API design / naming
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (commit `3c2cf33`, 2026-07-10)

> **Resolution:** Added a doc comment to `AnyPrompt` clarifying it is a
> concatenating prompt group/container, not a type erasure. The `Any` prefix
> signals "accepts any `Prompt`," not "erases a single concrete type."

> **Decision 2026-07-10 (user):** keep the `AnyPrompt` name; do **not** rename. Add a doc comment
> clarifying it is a concatenating prompt container/group (not a type eraser despite the `Any`
> prefix). Non-breaking, docs-only — the "Implementation Requirements" rename/grep steps below are
> superseded. (Context: 54 references, all in tests, but it is a public DSL entry point; the churn
> and CHANGELOG breakage weren't judged worth it.)

### Summary

Confirmed: `AnyPrompt` (`Sources/PKPrompt/PromptBuilder/Builder/Prompt/AnyPrompt.swift:5`)
is documented as "a transparent prompt container that resolves to the concatenated output
of its children" — it wraps `[any Prompt]` and concatenates. In Swift, the `Any*` prefix
conventionally signals type erasure (`AnyHashable`, `AnyView`, `AnySequence`,
`AnyCodable` elsewhere in this same codebase) — a single wrapped value hiding its
concrete type, not a collection/group. `AnyPrompt` here is a group, not an eraser.

### Implementation Requirements

- [ ] Rename to something that signals "group/container," e.g. `PromptGroup` or
      `PromptContainer` — check for name collisions with existing types
      (`AnyPrompt`'s sibling structural types like `PromptTuple`, `PromptArray` suggest
      `PromptGroup` reads consistently with the existing naming family).
- [ ] Grep all three consumers plus `PKPrompt`'s own examples/docs for `AnyPrompt` usage
      before renaming — this is used in prompt-composition call sites, likely a common
      type.

### Acceptance Criteria

- [ ] Type renamed; all call sites and doc references updated (including
      `docs/Architecture.md`/`AGENTS.md` mentions if any).
- [ ] `make verify` green; CHANGELOG updated (breaking rename).
