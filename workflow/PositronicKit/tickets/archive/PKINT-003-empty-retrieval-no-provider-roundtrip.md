# PKINT-003 — Guarantee No Provider Round-Trip for an Empty Retrieval Corpus

**Priority:** P2
**Type:** Performance / cost defect
**Depends on:** None
**Blocks:** Acceptable first-send latency for any consumer without a populated memory store
**Status:** Done (2026-07-05)
**Surfaced by:** YAK-25 (Yakamoz)

### Summary

Generalize YAK-25's `hasAnyMemory()` preflight into a stated guarantee — *the context
pipeline issues zero provider LLM round-trips when there is nothing to retrieve* — and cover
**every** stage that can make a model call (not only `MemoryRetrievalStage`), with a
regression test that asserts the provider is never called on an empty corpus.

### Current Problem

YAK-25 found `MemoryRetrievalStage` issued its own LLM call (tag generation) on every send,
before checking whether any memory corpus existed — 2–9.7s of latency on an empty
conversation. The fix added `MemoryStoreProtocol.hasAnyMemory()`
(`Sources/PositronicKit/Services/Database/MemoryStoreProtocol.swift:11`) and short-circuited
that one stage (`Sources/PositronicKit/Services/Context/Pipeline/Stages/MemoryRetrievalStage.swift:82`).

What is missing is a **guarantee** and its test. Other pipeline stages
(`ContextAssemblyStage`, ranking, any future retrieval stage) are not asserted to be cheap on
an empty corpus, and nothing prevents a future stage from re-introducing an eager round-trip.
The defect class — "a pipeline stage does expensive provider work before checking it has
anything to work on" — is unguarded.

### Files

- Audit: `Sources/PositronicKit/Services/Context/Pipeline/Stages/` (all stages).
- Modify if any stage makes an unconditional provider call: the offending stage(s).
- Add: a pipeline-level regression test asserting zero provider calls on an empty corpus.

### Implementation Requirements

1. Audit every context/memory pipeline stage for provider/LLM or embedding calls; gate each
   behind a cheap precondition (empty store / below-threshold corpus) consistent with the
   `hasAnyMemory()` pattern.
2. Where a cheap preflight does not already exist for a resource a stage consumes, add one to
   the relevant protocol (mirroring `hasAnyMemory()`), with a default implementation so
   existing conformers are unaffected.
3. Preserve all non-empty retrieval behavior exactly, including injected/mock stores with
   semantic results.
4. Prefer running independent cheap stages concurrently with prompt assembly where the
   existing structure allows, but correctness of the short-circuit is the requirement; the
   concurrency is optional.

### Required Tests

- A pipeline test with an empty memory/vector store asserts the injected mock provider records
  **zero** chat/embedding calls during context assembly, and `Context gathered` work is
  sub-threshold.
- A pipeline test with a populated store asserts retrieval behavior (tag generation, semantic
  matches) is unchanged from current.

### Acceptance Criteria

- [ ] No context/memory pipeline stage issues a provider or embedding call when its corpus is
      empty.
- [ ] A regression test asserts zero provider calls on an empty corpus at the pipeline level
      (not just one stage).
- [ ] Non-empty retrieval behavior is unchanged.
- [ ] `make verify` green; Monad/Shuttle build.

### Verification

```bash
swift test --filter ContextManagerTests
swift test --filter MemoryStoreWiringTests
make verify
```

### Handoff Notes

The existing single-stage fix is correct; this ticket is about the *guarantee* and the
*test that defends it*, so the cost regression cannot silently come back through a different
stage.

### Resolution

Done on `f04c2f8`. The empty-corpus fast path is now defended at the pipeline level with
regression coverage showing no tag generation or embedding work is performed when the memory
store is empty, while populated-store retrieval behavior remains intact.

Verification on 2026-07-05:

- `swift test --filter ContextManagerTests` passed.
- `make verify` in `PositronicKit` passed.
- Downstream consumer verification is currently blocked by unrelated compile drift:
  Monad and Shuttle still call `ChatRunRequest`, and Yakamoz currently fails on missing
  `TurnIdentity` / inspection-model symbols.
