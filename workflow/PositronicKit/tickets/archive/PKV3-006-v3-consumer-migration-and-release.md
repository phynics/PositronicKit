# PKV3-006 — Migrate consumers and qualify the v3 release

**Priority:** P1
**Type:** Release / integration
**Depends on:** PKV3-001, PKV3-002, PKV3-003, PKV3-004, PKV3-005, PKV3-007, PKV3-008, PKV3-009, PKV3-010, PKV3-011, PKV3-012, PKV3-013
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done

## Summary

Complete source-breaking migration in Monad, Shuttle, and Yakamoz, publish migration guidance, and qualify the next PositronicKit major release.

## Current Problem

- v3 removes/renames public composition, workspace, timeline, tool, and prompt symbols.
- Each consumer pins released PositronicKit and needs a local-path override for unreleased compatibility verification.

## Implementation Requirements

- Audit all consumers for every v3 removed/renamed symbol and migrate each call site.
- Add a migration table to CHANGELOG/release docs covering old symbols, replacement symbols, and behavior changes.
- Use documented local package overrides while running every consumer gate.
- Follow `PositronicKit/docs/Releasing.md` only after all package/consumer gates pass.

## Acceptance Criteria

- [x] Monad `swift test` (201 tests), Shuttle `swift test` (140 tests), and Yakamoz `make verify` (615 tests) pass against a local v3 PositronicKit override.
- [x] PositronicKit `make verify` passes (963 tests in 167 suites).
- [x] Release notes provide a complete source migration map (`PositronicKit/CHANGELOG.md` [3.0.0] section).
- [x] v3 tag/release follows the documented semver workflow (`3.0.0` tag created locally on PositronicKit `81eeb7a`; push tag to origin, then consumer pins will resolve).

## Resolution

- **PositronicKit**: added the v3 source migration map to `CHANGELOG.md`, ran `make verify`, and created the local annotated tag `3.0.0` at `81eeb7a`.
- **Monad**: migrated remaining v2 call sites (`ToolAPIController` `provenance` → `origin`, `llmService` → `languageModel`, `LLMConfiguration` flat-init usage in `StatusReportTests`), added `PKAnthropicProvider` dependency, bumped pin to `3.0.0`. Verified with local override: `swift test` 201 tests green. Commit `e5bec00`.
- **Shuttle**: migrated `llmService` → `languageModel`, `toolApprovalGate` → `toolApprovalPolicy`, added `PKUtilities` dependency, bumped pin to `3.0.0`. Verified with local override: `swift test` 140 tests green. Commit `552a3c3`.
- **Yakamoz**: migrated `ToolProvenance` → `ToolOrigin`, `provenance` → `origin`, `PromptInspecting` → `PromptObserving`, `Workspace` vocabulary, `LLMConfiguration` construction, `sidecarsIfEnabled`, `PKUtilities` imports, bumped pin to `3.0.0`. Verified with local override: `make verify` 615 tests green. Commit `4f3a3ba`.
- **Next step**: push the PositronicKit `3.0.0` tag to origin, then run `swift package resolve` / `make generate` in each consumer to update the resolved lockfiles and confirm remote builds.
