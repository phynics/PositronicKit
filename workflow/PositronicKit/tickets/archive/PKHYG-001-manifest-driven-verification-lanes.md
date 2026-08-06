# PKHYG-001 — Derive verification lanes from the SwiftPM manifest

**Priority:** P1
**Type:** Build / verification
**Depends on:** —
**Blocks:** PKHYG-003
**Triage:** ready-for-agent
**Status:** Done

**Resolution (2026-07-12):** Added `Scripts/list-library-products.swift` (Foundation `Decodable`
parsing `swift package describe --type json`, printing library products only). Replaced Makefile's
hardcoded `PRODUCTS` with derived list. Added `verify-examples` and `verify-tests` targets.
`verify` now composes pin/docs/linkage/products/examples/tests without duplicate test execution.
All 11 library products verified including `PKObservable`, `PKAnthropicProvider`,
`PKFoundationModelsProvider`. `make verify` green (948 tests). PositronicKit `8c0f6f9`.

## Summary

Replace Makefile's manually maintained product list with a manifest-derived library-product list, and give examples and tests their own explicit verification lanes.

## Current Problem

- `PositronicKit/Package.swift` declares public library products that `Makefile`'s `PRODUCTS` list omits: `PKObservable`, `PKAnthropicProvider`, and `PKFoundationModelsProvider`.
- `Makefile:20-28` maintains a second product inventory, so newly added products can silently miss the release gate.
- `verify-products` currently also builds the executable example, obscuring whether a failure is in a reusable library or in living documentation.

## Implementation Requirements

- Add `Scripts/list-library-products.swift`, using Foundation `Decodable` to consume `swift package describe --type json` and print every product whose type is `library`.
- Do not add `jq`, Python, or another external prerequisite.
- Replace `PRODUCTS` with a Makefile variable derived from the script output.
- Retain generated `verify-product-<name>` targets for every derived library product.
- Add `verify-examples` for `PositronicKitExamples` and `verify-tests` for `swift test`.
- Make `verify` compose pin validation, docs validation, default-linkage audit, libraries, examples, and tests once each.
- Update `.PHONY`, help text, and the macOS verification target to match the new contract.

## Acceptance Criteria

- [ ] `make verify-products` builds every public library product declared by `Package.swift`, including `PKObservable`, `PKAnthropicProvider`, and `PKFoundationModelsProvider`.
- [ ] `make verify-products` does not build `PositronicKitExamples`; `make verify-examples` does.
- [ ] `make verify-tests` executes the normal test suite.
- [ ] `make verify` includes products, examples, docs, linkage, and tests without duplicate test execution.
- [ ] No external JSON-processing tool becomes a development prerequisite.

