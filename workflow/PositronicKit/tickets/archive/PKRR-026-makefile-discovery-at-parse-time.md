---
Priority: P2
Type: Bootstrap ergonomics
Depends: —
Blocks: —
Triage: needs-triage
Status: Done
Confidence: Confirmed
Owner: Build engineering
Effort: S
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-026
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `a44a06a` (merge `c3d61fa`). Moved
`swift package describe` from parse-time to `verify-products` recipe. Added `doctor`
target with actionable prerequisite checks. Container targets fail with one clear message
when no runtime exists. `make help` works without Swift on PATH. 1583 tests in 236 suites
pass on merged main.
---

# PKRR-026 — The Makefile performs Swift package discovery at parse time and container targets lack a clear runtime guard

## Summary
`swift package describe` is evaluated while parsing most Make targets, so even
`make help` or unrelated targets can fail before execution when Swift/dependencies
are unavailable. Docker/Podman commands invoke a possibly empty
`CONTAINER_RUNTIME`, producing cryptic shell errors.

## Current problem
- `Makefile:26-49` — `swift package describe` is evaluated while parsing most Make
  targets.
- `Makefile:188-208` — Docker/Podman commands invoke a possibly empty
  `CONTAINER_RUNTIME`.

## Impact
Even `make help` or unrelated targets can fail before execution when
Swift/dependencies are unavailable. Missing container runtime produces cryptic
shell errors.

## Recommended change
Move product discovery into the `verify-products` recipe or a generated include. Add
explicit `doctor` and preflight checks for Swift, Rust, native dependencies,
Docker/Podman, model assets, and host platform.

## Acceptance criteria
- [x] `make help` works without Swift/dependency resolution.
- [x] `make doctor` reports actionable missing prerequisites.
- [x] Container targets fail with one clear message when no runtime exists.
- [x] Regression: confirm `make verify` still derives products correctly after the
  move.
- [x] `CHANGELOG.md` updated under Unreleased (build change).

## Verification
`make help` and `make doctor` in a stripped environment; `make verify` in a full
environment. Coordinate with PKRR-025 (CI matrix).
