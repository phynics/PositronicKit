# PKCLEAN-006 — Remove unadopted helpers: `PipelineBuilder`, throwing `assertUniqueIDs`, ID-validation wrappers

**Priority:** P3
**Type:** Dead-code removal
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `c545d85`, merged `cbe49e0`) — `PipelineBuilder.swift` and
`PromptSectionIDValidation.swift` deleted; throwing `assertUniqueIDs()`/`CollectionUniqueIDError`
removed from `Collection+UniqueIDs.swift` (non-throwing `duplicateIDs(idKeyPath:)` promoted to
`public`). Call sites in `PromptAssembler.swift`/`TimelinePromptHistory.swift` migrated. Ticket's
premise was slightly stale: a plain-text grep for `PipelineBuilder` missed
`Tests/PositronicKitTests/ContextPipelineBuilderTests.swift`, which used the DSL via trailing-closure
syntax (`Pipeline<Context,Event> { ... }`) without spelling the type name — caught when `swift test`
failed to compile; those 4 constructions were rewritten to imperative `Pipeline().add(...)` chaining.
Downstream grep (Monad/Shuttle/Yakamoz) clean (one doc hit in `Monad/docs/CONTEXT_SYSTEM.md` was a
false positive — different symbols `@ContextPipelineBuilder`/`@PromptAssemblyPipelineBuilder`).
`swift test` green (925 tests / 159 suites). CHANGELOG updated (3 breaking-removal entries).

### Summary

Three small pieces of never-adopted infrastructure:

- `Sources/PKShared/Utilities/PipelineBuilder.swift` — `@resultBuilder` never referenced
  outside its own file; pipelines are assembled imperatively via `Pipeline.add()`.
- `Sources/PKPrompt/Support/Collection+UniqueIDs.swift` — the throwing
  `assertUniqueIDs()` overloads and `CollectionUniqueIDError` are exercised only by
  `PKPromptTests/Core/PromptSectionValidationTests.swift`; all production call sites use
  the non-throwing `duplicateIDs(idKeyPath:)`.
- `Sources/PKPrompt/Support/PromptSectionIDValidation.swift` — two four-line typed
  wrappers around `duplicateIDs(idKeyPath: \.id)`.

### Implementation Requirements

1. Confirm zero downstream references (Monad/Shuttle/Yakamoz grep for `PipelineBuilder`,
   `assertUniqueIDs`, `CollectionUniqueIDError`, `duplicatePromptSectionIDs`,
   `duplicateRenderedPromptSectionIDs`), then delete all three.
2. Migrate/delete the test-only coverage of the throwing overloads; switch wrapper call
   sites to `duplicateIDs(idKeyPath: \.id)` directly.
3. CHANGELOG `Unreleased` → `Removed` (public API removals — flag semver implications).

### Acceptance Criteria

- [ ] Three files removed; call sites migrated.
- [ ] Downstream grep clean.
- [ ] `make verify` green; CHANGELOG updated.
