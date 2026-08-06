---
Priority: P2
Type: API hygiene / unused surface
Depends: —
Blocks: —
Triage: needs-triage
Status: Done
Confidence: High-confidence candidates; verify with symbol graph
Owner: API maintainers
Effort: M
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-028
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Completed 2026-07-29. PositronicKit `4f69e6f`. Symbol-graph and repository/downstream
scans produced a disposition report. Compatibility APIs and Codable-only event cases were
retained with documented deprecation/consumer-constructed stories; no safe removals were made.
---

# PKRR-028 — Several public/runtime APIs appear orphaned or test-only and need an intentional disposition

## Summary
Candidate orphaned surface: `registerTask` has no production caller in
repository-wide search; `MetaEvent.generationCompleted` and
`CompletionEvent.streamCompleted` have no production producer found; the deprecated
`llmService` compatibility surface remains alongside v3 naming. Dead surface
increases exhaustive-switch burden, documentation cost, compatibility constraints,
and false expectations. Conversely, removing compatibility APIs without downstream
analysis has caused regressions before (e.g. PKHYG-002 removing `PKTestSupport`).

## Current problem
- `Sources/PositronicKit/Services/Timeline/TimelineManager.swift:259-270` —
  `registerTask` has no production caller in repository-wide search (also relevant
  to PKRR-002).
- `Sources/PKShared/SharedTypes/ChatEvent.swift:122-163` —
  `MetaEvent.generationCompleted` and `CompletionEvent.streamCompleted` have no
  production producer found (also relevant to PKRR-011).
- `Sources/PositronicKit/PositronicKit.swift:44-47` — deprecated `llmService`
  compatibility surface remains alongside v3 naming.

## Impact
Dead surface increases exhaustive-switch burden, documentation cost, compatibility
constraints, and false expectations. Conversely, removing `PKTestSupport` or
compatibility APIs without downstream analysis has caused regressions before.

## Recommended change
Run `swift symbolgraph-extract`, package-interface diffing, and downstream usage
scans. Classify each candidate as `implement`, `deprecate with removal release`,
`package-scope`, or `document as consumer-constructed`. Record downstream
dependencies before removal.

## Verification required before any removal (why `needs-triage`)
This finding is intentionally a candidate set. Verify with Swift symbol graphs and
downstream repository searches (`Monad`/`Shuttle`/`Yakamoz`/`LandGo`) before
removing anything. The review could not run `swift package dump-symbol-graph` or
clone downstream repos.

## Acceptance criteria
- [ ] Every public symbol has a documented story and at least one
  production/example/downstream consumer, or a deprecation plan.
- [ ] No event case exists without a defined producer/consumer contract (relates to
  PKRR-011).
- [ ] Symbol-graph + downstream scan results recorded in the ticket resolution.
- [ ] `CHANGELOG.md` updated under Unreleased for any removal/deprecation.

## Verification
`swift package dump-symbol-graph`; downstream grep across `Monad`/`Shuttle`/`Yakamoz`
/`LandGo`. Do not remove compatibility surface without recording downstream
dependencies (historical precedent: PKHYG-002).
