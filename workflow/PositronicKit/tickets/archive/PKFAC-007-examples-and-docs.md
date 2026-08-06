# PKFAC-007 — Examples + type docs for the operation ladder

**Priority:** P3
**Type:** Docs / examples
**Depends on:** PKFAC-004, PKFAC-005, PKFAC-006
**Blocks:** —
**Triage:** wontfix
**Status:** Done — five-tier docs, examples, README, and changelog updates implemented in `a41c444`; examples compiled. Full verification was later blocked by unrelated uncommitted tool API changes in the checkout.

Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) §2.

### Summary

Make the ladder discoverable in living documentation once the tiers exist.

### Implementation Requirements

- [ ] Update `PositronicKit`'s type doc comment to state the ladder explicitly (tier 1 one-shot → tier 2
      Conversation → tier 3 `timelineManager` → tier 4 `AgenticRuntime` → tier 5 raw), with the intended
      "wrap in a Service class, pass vended managers to subsystems" consumer pattern.
- [ ] Add `PositronicKitExamples` factories in ascending tier order: minimal one-shot (first/simplest),
      minimal conversation, agentic runtime — each compiling against the real public surface.
- [ ] Update `READMEExamples.swift` / README snippets if they reference the old struct/init surface.
- [ ] CHANGELOG entry summarizing the facade redesign surface change.

### Acceptance Criteria

- [ ] `PositronicKitExamples` demonstrates every tier and compiles under `make verify`.
- [ ] Type doc names all five tiers.
- [ ] `make verify` green.
