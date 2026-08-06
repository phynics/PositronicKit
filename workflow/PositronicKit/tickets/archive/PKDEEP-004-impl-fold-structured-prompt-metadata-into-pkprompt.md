# PKDEEP-004-impl — Fold StructuredPromptMetadata into PKPrompt

**Priority:** P3
**Type:** Implementation (deepening)
**Depends on:** PKDEEP-004 (research, done)
**Blocks:** none
**Triage:** ready-for-agent
**Status:** Done (2026-07-08, commit `dd7ce01`)

### Summary

Fold the comment-enforced `StructuredPromptMetadata` helper from the runtime side
(`PositronicKit/Services/Prompting/`) into PKPrompt as a `nodeMetadata(renderedContent:)`
method on `PromptSection` and `RenderedPrompt.Section`. Delete the runtime-side
`StructuredPromptMetadata` enum. Fix the latent `TokenBudget.defaultNodeHash` inconsistency
that omits `renderedContent` from its hash inputs.

### Context

Research ticket PKDEEP-004 confirmed:
- `StructuredPromptMetadata.makeNodeMetadata` has exactly 2 production callers, both reading
  the same fields (`id`, `estimatedTokens`, `priority`, `cachePolicy`, `path`,
  `renderedContent`) from `PromptSection` / `RenderedPrompt.Section` (both PKPrompt types).
- The helper calls `StableHash.hash(components:)` (PKShared, already a PKPrompt dependency)
  and returns `StructuredNodeMetadata` (PKPrompt type). Zero runtime dependencies.
- The comment-enforced invariant ("Keep this in sync with TimelinePromptHistory via
  StructuredPromptMetadata") becomes a compiler-enforced method on the type that owns the fields.
- Direction (a) (push assembly end-to-end into PKPrompt) is blocked because
  `LLMPromptRequest` lives in PositronicKit, not PKShared — circular dependency.
- `TimelinePromptHistory` stays runtime-side (justified by delta table in research).
- `TokenBudget.defaultNodeHash` (PKPrompt) hashes `[id, estimatedTokens, priority,
  cachePolicy]` — omits `renderedContent`, diverging from `StructuredPromptMetadata`.

### Implementation requirements

1. **Add `nodeMetadata(renderedContent:)` to `PromptSection`** in PKPrompt
   (`Sources/PKPrompt/PromptAssembly/PromptSection.swift` or a new
   `PromptSection+Metadata.swift` extension file):
   ```swift
   func nodeMetadata(renderedContent: String) -> StructuredNodeMetadata {
       StructuredNodeMetadata(
           path: path,
           nodeHash: StableHash.hash(components: [
               id,
               String(estimatedTokens),
               String(priority),
               String(describing: cachePolicy),
               renderedContent,
           ])
       )
   }
   ```

2. **Add `nodeMetadata(renderedContent:)` to `RenderedPrompt.Section`** in PKPrompt
   (`Sources/PKPrompt/PromptAssembly/RenderedPrompt+Section.swift` or a new extension file).
   Same implementation — both types expose the same fields.

3. **Delete `Sources/PositronicKit/Services/Prompting/StructuredPromptMetadata.swift`**
   (53 lines). The runtime-side enum is fully replaced by the PKPrompt methods.

4. **Update `PromptAssembler.buildStructuredMetadata`** (`PromptAssembler.swift:203-218`)
   to call `section.nodeMetadata(renderedContent:)` instead of
   `StructuredPromptMetadata.makeNodeMetadata(for:section, renderedContent:)`. Remove the
   "Keep this in sync" comment at line 211.

5. **Update `TimelinePromptHistory.nodeMetadata(prompt:)`** (`TimelinePromptHistory.swift:406-418`)
   to call `section.nodeMetadata(renderedContent:)` instead of
   `StructuredPromptMetadata.makeNodeMetadata(for:section, renderedContent:)`.

6. **Fix `TokenBudget.defaultNodeHash(for:)`** (`TokenBudget.swift:245-252`) to include
   `renderedContent` in its hash inputs, aligning with the new `nodeMetadata` method. Since
   `defaultNodeHash` is sync and `PromptSection.renderedContent()` is async, the simplest
   fix is to have `defaultNodeHash` accept an optional `renderedContent: String?` parameter
   (defaulting to `nil`), and include it in the hash when non-nil. Audit the call site at
   line 134 to pass available rendered content. If the content is not available at the call
   site (because the section hasn't been rendered yet), document why the fallback hash
   intentionally omits content and leave it as-is with a comment — but this should be
   verified, not assumed.

7. **Move tests**: The `StructuredPromptMetadata` test cases in
   `Tests/PositronicKitTests/TimelinePromptHistoryTests.swift` (lines 71, 103, 107) that
   use `StructuredPromptMetadata.makeNodeMetadata(...)` directly should move to
   `Tests/PKPromptTests/` and test `PromptSection.nodeMetadata(renderedContent:)` and/or
   `RenderedPrompt.Section.nodeMetadata(renderedContent:)` directly. Runtime-side tests
   that verify the *callers* (`PromptAssembler` and `TimelinePromptHistory`) continue to
   exist but no longer reference `StructuredPromptMetadata`.

### Acceptance criteria

- [ ] `func nodeMetadata(renderedContent: String) -> StructuredNodeMetadata` exists on
      `PromptSection` (PKPrompt, public or package)
- [ ] Same method exists on `RenderedPrompt.Section` (PKPrompt, public or package)
- [ ] `StructuredPromptMetadata.swift` deleted from runtime
- [ ] `PromptAssembler.buildStructuredMetadata` calls the PKPrompt method
- [ ] `TimelinePromptHistory.nodeMetadata(prompt:)` calls the PKPrompt method
- [ ] "Keep this in sync" comment removed
- [ ] `TokenBudget.defaultNodeHash` inconsistency resolved (either fixed or documented)
- [ ] Tests moved to `PKPromptTests`; runtime tests updated
- [ ] `make verify` green (pin, docs, linkage, tests)
- [ ] No downstream breakage (all symbols are package-internal — confirmed zero consumer
      references)

### Downstream sync

All affected symbols (`StructuredPromptMetadata`, `PromptAssembler`,
`TimelinePromptHistory`) are package-internal. Zero downstream references confirmed by
grep. No consumer pin bump or coordination needed.

### Verification

```bash
cd PositronicKit
make verify
```

### Cross-links

- Research: [PKDEEP-004](../PKDEEP-004-prompting-vs-pkprompt-duplication.md)
- Related: PKDEEP-001 (assembly stage collapse, done), PKDEEP-006 (projection/messages fold)
