---
Priority: P1
Type: API design
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Resolution: Completed 2026-08-04 in PositronicKit 7aeb3ca. Clarified provider side effects and
  support APIs, preserved compatibility shims, and verified native and cross-platform gates.
Confidence: High
Owner: —
Effort: M
Review: Swift API Design Guidelines review 2026-08-04
Pinned revision: ebd61d5
---

# PKAPI-003 — Improve provider and support API clarity

## Summary

Make provider factory side effects, cross-platform embedding labels, closure roles, and test-runtime
facade access clear at the point of use without breaking existing callers.

## Current problem

- Provider `makeClient` functions also mutate the global structured-output adapter registry.
- `LocalEmbeddingService` uses `modelDirectory:` on Linux and `miniLMModelDirectory:` on Apple.
- `FoundationModelsClient.SessionFactory` omits closure parameter roles.
- `PKTestSupport.TestRuntime.buildCore()` returns an already-created stored facade.
- `PKFastEmbedError.nativeFailure(Int32, String)` and related public cases lack role labels/docs;
  changing case labels is major-release work.

## Implementation requirements

1. Add a canonical imperative provider factory name that reveals construction plus adapter
   registration; deprecate `makeClient` and forward it. Do not change runtime registration behavior.
2. Make `miniLMModelDirectory:` canonical on every supported platform; retain a deprecated Linux
   `modelDirectory:` forwarding initializer.
3. Name `SessionFactory` closure parameters for tools and instructions.
4. Add a noun-like `TestRuntime.positronicKit` property; deprecate `buildCore()` as a forwarder.
5. Add useful documentation to every public `PKFastEmbedError` case. Do not add duplicate cases or
   break case pattern matching; record associated-value labels for the next major release.
6. Update provider examples and tests. Audit Monad, Shuttle, Yakamoz, and LandGo and record the
   canonical migrations; do not commit downstream calls to APIs their released pins do not yet
   contain. Migrate those calls with a later released-pin bump.
7. Add tests covering forwarding behavior and equivalent MiniLM initializer semantics.
8. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [x] Canonical provider calls reveal their registration side effect.
- [x] MiniLM initializer spelling is platform-stable.
- [x] Public closure parameters have role names.
- [x] TestRuntime access reads as noun-like state access.
- [x] Existing public calls remain available as deprecated shims.
- [x] Major-only `PKFastEmbedError` label work is documented without duplicating semantics.
- [x] Provider/support focused tests pass and downstream audits are recorded.
- [x] `CHANGELOG.md` is updated.

## Verification and downstream audit

- `make verify`, `make verify-products`, `make verify-minilm`, and
  `make verify-linux-current`: passed. MiniLM ran 13 contract tests and 23 native-wrapper tests.
- Monad, Shuttle, Yakamoz, and LandGo were searched for affected factories, embedding labels, and
  TestRuntime access. Their released pins retain the existing shapes; no downstream edit was
  appropriate before a released-pin bump.
