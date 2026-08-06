---
Priority: P2
Type: Documentation correctness
Depends: PKRR-011
Blocks: —
Triage: needs-triage
Status: Done
Confidence: Confirmed
Owner: Docs / API
Effort: S
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-027
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `b1a5d20` (merge). Fixed all stale
snippets in `docs/Usage.md`: grouped `Configuration` init, `ChatRunRequest`, current event
case names (`.reasoning`, PKRR-011 terminals, `ErrorIdentity.isBlocked`). Added
`compile-doc-snippets` Makefile target wired into `verify`. Added `consumeChatEventStream`
to examples. 1576 tests in 235 suites pass on merged main.
---

# PKRR-027 — Usage documentation contains non-compiling event names and stale construction APIs

## Summary
`docs/Usage.md` examples use initializer shapes that differ from the current grouped
`Configuration` API. The event switch uses `.thinking` while the current case is
`.reasoning`, and pattern-matches an outdated error shape. The main integration
guide cannot be copied into an application and undermines confidence in the public
story.

## Current problem
- `docs/Usage.md:40-84` — examples use initializer shapes that differ from the
  current grouped `Configuration` API.
- `docs/Usage.md:117-167` — the switch uses `.thinking` while the current case is
  `.reasoning`, and pattern-matches an outdated error shape.
- `Sources/PKShared/SharedTypes/ChatEvent.swift:107-163` — current event case
  names/shapes differ from the guide.

## Impact
The main integration guide cannot be copied into an application and undermines
confidence in the public story.

## Recommended change
Compile all documentation snippets as executable example targets or DocC tests.
Generate event handling examples from one canonical source and add an API-diff gate
for docs.

## Acceptance criteria
- [x] Every published snippet compiles at the pinned release.
- [x] Docs do not describe un-emitted events (relates to PKRR-011).
- [x] An API-diff/compile-docs gate is added to `make verify`/CI (relates to
  PKRR-025).
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`make verify` docs gate green; snippets compile. Depends on PKRR-011 for the
canonical terminal-event vocabulary.
