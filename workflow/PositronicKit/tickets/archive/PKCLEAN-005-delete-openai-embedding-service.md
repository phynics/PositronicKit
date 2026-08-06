# PKCLEAN-005 — Delete unused `OpenAIEmbeddingService`

**Priority:** P3
**Type:** Dead-code removal
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `24e9467`, merged `d4e4362`) — `OpenAIEmbeddingService.swift`
deleted; downstream grep (Monad/Shuttle/Yakamoz) clean, no doc/README/llms.txt mentions found.
`swift test` green (926 tests / 159 suites). CHANGELOG `Removed` entry added, flagged for release
captain (was public in 1.x).

### Summary

`Sources/PKOpenAIProvider/OpenAIEmbeddingService.swift` has zero references across
PositronicKit, Monad, Shuttle, and Yakamoz — never instantiated, imported, or directly
tested. Production embedding paths use `LocalEmbeddingService` or `NoOpEmbeddingService`.
Abandoned experiment; delete it.

### Implementation Requirements

1. Re-run the downstream grep (`OpenAIEmbeddingService` across all four repos) to confirm
   it is still unreferenced, then delete the file.
2. Remove any doc/llms.txt/README mention.
3. CHANGELOG `Unreleased` → `Removed` entry (public API removal — note it for the next
   minor/major per semver policy; if it was public in 1.x, flag for the release captain).

### Acceptance Criteria

- [ ] File deleted; grep clean in all four repos.
- [ ] `make verify` and `make verify-products` green.
- [ ] CHANGELOG updated.
