# PositronicKit Release-Hygiene Tranche — Design

**Date:** 2026-07-12  
**Status:** Draft — pending review  
**Scope:** Build verification, test-target ownership, internal test support, and documentation/layout authority. No runtime behavior or public API removal.

## Context

The July architecture review found little confidently dead implementation. The immediate drift risk is instead duplicated ownership: the manifest declares products that `make verify-products` does not build; core tests own provider and shared-contract coverage; and a test-only helper target is published as a library product. The package has already completed a facade redesign and an earlier TimelineManager extraction/re-collapse cycle. This tranche must not reopen either decision.

## Goals

1. Make build verification derive from the package manifest rather than a manually maintained product list.
2. Make tests primarily live with the production module whose behavior they verify.
3. Keep test support internal to the package.
4. Give each documentation artifact one explicit source of truth.

## Non-goals

- Removing or deprecating supported public runtime symbols.
- Changing `TimelineManager`, workspace seams, or provider capability semantics.
- Removing the behavioral examples coverage that intentionally makes `PositronicKitTests` depend on `PositronicKitExamples`.
- Releasing a new PositronicKit version as part of this work.

## Decisions

### 1. Package manifest is the build-product authority

`Package.swift` is the sole authoritative declaration of package products. The Makefile must query `swift package describe --type json` to derive product names instead of maintaining `PRODUCTS` by hand.

The Makefile exposes four independently runnable lanes:

| Target | Contract |
|---|---|
| `verify-products` | Builds every public library product declared in `Package.swift`. |
| `verify-examples` | Builds the `PositronicKitExamples` executable product. |
| `verify-tests` | Runs the normal Swift test suite. |
| `verify` | Composes docs validation, product verification, example verification, and tests. |

`verify-products` intentionally excludes executables. An executable has a different contract—living documentation and sample composition—so its failure belongs to `verify-examples`, not an ambiguous product lane.

The Makefile may use `jq` only if it is already an explicit development prerequisite; otherwise it must parse the JSON using a tool available to the supported macOS/Linux development environments. The implementation plan must choose and document that portability mechanism before editing Makefile behavior.

### 2. Test targets follow production ownership

Provider-specific tests move out of `PositronicKitTests` into one test target per provider adapter. Tests for `PKShared` value types, contracts, utilities, and tools move to `PKSharedTests`. `PositronicKitTests` retains core-runtime behavior, cross-module runtime integration, and existing examples story tests.

This is a package-internal ownership seam, not a production API change. New test targets must avoid reintroducing a broad core dependency on concrete provider SDKs.

### 3. PKTestSupport is internal test infrastructure

`PKTestSupport` is not a supported consumer library. Remove it from `Package.products` while retaining it as a package target at `Tests/PKTestSupport`, where it can be used by package test targets. Do not move it under `Sources/`; source location should express that it is test infrastructure.

The package must keep its dedicated `PKTestSupportTests` target. Internal visibility and target dependency declarations should be adjusted only as required by SwiftPM after the product removal.

### 4. Documentation has one authority per artifact

The excluded `Sources/PositronicKit/README.md` must not duplicate maintained usage guidance. Delete it if its content is already represented in root documentation/DocC; otherwise reduce it to an ownership pointer and include it in validation.

For `docs/index.html` and `llms.txt`, first classify each artifact as either:

- generated output: generation command is documented and CI reproduces/diffs it; or
- authored source: its source and validator are named explicitly.

This tranche selects the smallest path that makes drift detectable. It does not create a new documentation site or change published documentation content beyond authority pointers.

### 5. Remove raw-text tool-call inference after a downstream audit

`ToolOutputParser` is live code, invoked by `ToolCallExtractionStage` as a fallback for models
that emit tool calls in assistant text. It recognizes pipe markers, XML blocks, and fenced JSON.
The existing `availableTools` guard is retained until removal, but the parser still turns
model-generated text into an executable tool request.

The package direction is provider-native structured tool calls only. Before removal, audit
Monad, Shuttle, and Yakamoz for non-native-model tool use and document the result. If no consumer
requires fallback parsing, delete `ToolOutputParser`, its extraction-stage invocation, and only
the dedicated raw-text parser/regression fixtures. Retain the ordinary structured tool-call path,
approval gate, and all provider-native tool coverage.

After removal, an assistant response containing XML, pipe markers, or fenced JSON is ordinary
assistant content; it must never create a tool call. This is an intentional behavior change and
requires a CHANGELOG entry and a release-note migration note for users of non-native tool-calling
models.

### 6. Generic utility relocation is evidence-led

Only relocate utilities when their owning runtime domain is unambiguous and the move reduces a generic bucket without changing their interface. Candidates include `RetryPolicy` and `VectorMath`. `ToolOutputParser` is handled by the explicit removal decision above, not by a file move.

## Alternatives considered

### Keep a hand-maintained `PRODUCTS` list

Rejected. It is the current drift source. Reviewers cannot reliably notice every new product without comparing two independent declarations.

### Include examples in `verify-products`

Rejected. It conflates reusable public libraries with the executable documentation contract. A separate lane yields clearer failures while `verify` still enforces both.

### Keep PKTestSupport as a public product and move it to Sources

Rejected. The package owners clarified that it is an internal collection of testing utilities; publishing it commits the target to semver support without a consumer need.

### Re-extract TimelineManager internals while reorganizing tests

Rejected. The prior extraction created hypothetical seams and was intentionally folded back into actor extension files. This tranche focuses only on release hygiene.

## Verification

- `make verify-products` must build every declared public library product, including new products added by a temporary manifest-fixture or a verification assertion.
- `make verify-examples` must build the executable.
- `make verify-tests` and `make verify` must execute tests rather than report a zero-test success.
- Each relocated test target must pass independently and the full suite must pass.
- `PKTestSupport` must not appear in `swift package describe --type json` products while all package test targets that use it still build.
- Documentation validation must detect the chosen generated/authored artifact contract.

## Delivery shape

Create five tickets in dependency order:

1. Makefile manifest-driven verification lanes.
2. Remove PKTestSupport from the public product surface.
3. Realign provider and PKShared test targets.
4. Establish documentation/layout authority and perform evidence-led utility relocation only where independent.
5. Remove raw-text tool-call inference after a downstream usage audit.

Tickets 2 and 3 may proceed after ticket 1; ticket 4 remains independent unless its validation changes depend on the new Makefile lanes.
Ticket 5 is independent of tickets 1–4 but must not start until its consumer audit is complete.
