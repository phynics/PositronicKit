---
Priority: P2
Type: Build / CI
Depends: —
Blocks: —
Triage: needs-triage
Status: Done
Confidence: Confirmed
Owner: Build engineering
Effort: M
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-025
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-29. PositronicKit `8c778c8`. Added pinned macOS, iOS,
Linux minimum, and Linux current CI jobs with explicit product/docs/example exclusions and
test artifacts. Final merged main verification passed with 1598 tests in 237 suites.
---

# PKRR-025 — CI does not exercise the package's documented verification matrix

## Summary
The CI workflow has only one Linux job running `make verify-linux-current`. macOS
`verify` runs docs, linkage, products, examples, and tests; Linux current only runs
two test variants. The package declares macOS and iOS products (Foundation Models,
Observable). Apple-only compile breaks, DocC/docs drift, product linkage, examples,
and iOS availability issues can merge without a gate. `verify-linux-minimum` and
`verify-linux-current` are currently identical aliases.

## Current problem
- `.github/workflows/ci.yml:12-60` — the workflow has only one Linux job running
  `make verify-linux-current`.
- `Makefile:122-164` — macOS verify runs docs, linkage, products, examples, and
  tests; Linux current only runs two test variants.
- `Package.swift:6-25` — the package declares macOS and iOS products including
  Foundation Models and Observable modules.

## Impact
Apple-only compile breaks, DocC/docs drift, product linkage, examples, and iOS
availability issues can merge without a gate. `verify-linux-minimum` and
`verify-linux-current` are currently identical aliases.

## Recommended change
Add macOS and iOS compile/test jobs; run docs/examples/product builds where
supported; define an actual minimum Swift job; pin third-party actions to commit
SHAs; publish test/coverage artifacts.

## Acceptance criteria
- [ ] Every public product builds on each supported platform or has an explicit
  exclusion.
- [ ] Docs/examples are compiled in CI (relates to PKRR-027).
- [ ] Minimum and current toolchain jobs use different pinned versions.
- [ ] Third-party actions are pinned to commit SHAs.
- [ ] Test/coverage artifacts are published.
- [ ] `CHANGELOG.md` updated under Unreleased (CI change).

## Verification
Inspect `.github/workflows/`; confirm macOS/iOS jobs are green on a PR. Coordinate
with PKRR-026 (Makefile preflight).
