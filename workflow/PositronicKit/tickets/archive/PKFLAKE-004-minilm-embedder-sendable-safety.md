# PKFLAKE-004 — `MiniLMEmbedder` `@unchecked Sendable` over raw C handle

**Priority:** P2
**Type:** Bug (potential data race)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `11a7519`) — investigated the native bridge
(`native/pkfastembed/src/lib.rs`): `pkfe_model_embed`/`pkfe_model_embed_batch` both serialize on
a Rust `Mutex<TextEmbedding>` before calling into FastEmbed/ONNX Runtime, so concurrent `embed`
calls are C-level reentrant-safe; only `pkfe_model_destroy` (called from `deinit`) is unsafe to
race against an in-flight embed. The sole production owner, `PKMiniLMPlatformBackend`, is an
actor whose isolation guarantees no in-flight call during its own deallocation. Grepped Monad,
Shuttle, Yakamoz — zero direct `MiniLMEmbedder` references. Added a doc comment on the
declaration citing the Mutex + single-owner contract (option 3: cite reentrancy, since it's
verified true) and a concurrency smoke test (16 concurrent `embed` calls via a fake `NativeAPI`
tracking a high-water mark ≥ 2, proving genuine overlap without corruption). `swift test`: 896
default tests green; `make verify-minilm`: 21 tests / 2 suites green (ran successfully on this
host).

### Summary

`MiniLMEmbedder` (`Sources/PKFastEmbed/PKFastEmbed.swift:18`) is a `public final class`
holding an `OpaquePointer` into C native state, declared `@unchecked Sendable` with no
lock or actor guarding concurrent `embed`/`embedBatch` calls. Unless the C library is
verified reentrant, concurrent embedding requests are a data race.

### Implementation Requirements

1. Determine the thread-safety contract of the native `CPKFastEmbed` handle (check
   `native/` sources and its upstream docs).
2. If not reentrant (or unverifiable): serialize access — either convert the wrapper to
   an actor, or guard the handle with a `Mutex`/serial isolation while keeping the
   public async surface. Note `PKMiniLMPlatformBackend` is already an actor — if all
   production access is via that actor, the fix may be to make `MiniLMEmbedder`
   non-Sendable/internal and document the single-owner contract instead.
3. If reentrant: keep `@unchecked Sendable` but add a source comment citing the
   guarantee, and a concurrent-batch smoke test.
4. Check consumers (Monad, Shuttle, Yakamoz) for direct `MiniLMEmbedder` use before
   changing access levels (per downstream-sync checklist).

### Acceptance Criteria

- [ ] Concurrency contract of the C handle documented at the declaration.
- [ ] Either serialization added or reentrancy cited; no unguarded `@unchecked Sendable`.
- [ ] `make verify` green; `make verify-minilm` green if runnable on this host.
