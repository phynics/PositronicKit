# PKHYG-002 — Keep PKTestSupport internal to package tests

**Priority:** P2
**Type:** Package surface cleanup
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done

**Resolution (2026-07-12):** Deleted the `.library(name: "PKTestSupport", targets: ["PKTestSupport"])`
product declaration from `Package.swift`. The target remains in `Tests/PKTestSupport` and all
test-target dependencies are preserved. `swift package describe --type json` no longer reports
`PKTestSupport` as a product. `swift test --filter PKTestSupportTests` passes (9 tests).
PositronicKit `b3230b0`.

## Summary

Remove `PKTestSupport` from PositronicKit's public product surface while retaining it as internal test infrastructure under `Tests/PKTestSupport`.

## Current Problem

- `PositronicKit/Package.swift` publishes `.library(name: "PKTestSupport", targets: ["PKTestSupport"])`.
- The target's sources are test fixtures, mocks, and helpers in `Tests/PKTestSupport`.
- Publishing the target creates an unnecessary semver commitment and makes its test-only ownership ambiguous.

## Implementation Requirements

- Delete only the `PKTestSupport` library product declaration.
- Keep the `PKTestSupport` target in `Tests/PKTestSupport` and retain `PKTestSupportTests`.
- Preserve all package test-target dependencies that import `PKTestSupport`.
- Do not move the target into `Sources/` or alter fixture behavior.

## Acceptance Criteria

- [ ] `swift package describe --type json` no longer reports `PKTestSupport` as a package product.
- [ ] `swift test --filter PKTestSupportTests` passes.
- [ ] The full package test suite still builds all targets that use `PKTestSupport`.
- [ ] No downstream consumer migration is required.

