# PKHYG-004 — Define documentation and layout authority

**Priority:** P3
**Type:** Documentation / housekeeping
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done

**Resolution (2026-07-12):** Deleted duplicative `Sources/PositronicKit/README.md` and removed
dead `exclude: ["README.md"]` from `Package.swift`. Extended `Scripts/validate-docs.sh` with
authority contracts: `docs/index.html` validated for version-pin consistency with `README.md`;
`llms.txt` validated for path-reference integrity. Both are authored artifacts (no generator).
948 tests green. PositronicKit `b890e08`.

## Summary

Eliminate duplicate runtime documentation and make validation explicitly cover the authority contract for every tracked documentation artifact.

## Current Problem

- `Sources/PositronicKit/README.md` is excluded from the SwiftPM target and duplicates package usage guidance, including outdated facade construction examples.
- `docs/index.html` and `llms.txt` are tracked but are not covered by the current `Scripts/validate-docs.sh` story and DocC checks.
- Reviewers cannot tell whether these artifacts are generated outputs or authored source, so they can drift silently.

## Implementation Requirements

- Determine from current scripts/history whether `docs/index.html` and `llms.txt` have an existing trustworthy generator.
- For each artifact, record one contract: generated with a reproducibility/diff check, or authored with a named source and validation check.
- Do not introduce a new site-generation system if no generator already exists.
- Delete `Sources/PositronicKit/README.md` if fully duplicative; otherwise reduce it to an ownership pointer without runnable examples.
- Extend `Scripts/validate-docs.sh` to enforce the chosen contracts while preserving story and DocC validation.

## Acceptance Criteria

- [ ] No target-local README duplicates runtime usage instructions.
- [ ] `docs/index.html` and `llms.txt` each have one documented authority and a validation path.
- [ ] `make validate-docs` fails when a generated artifact drifts or an authored artifact violates its documented validation rule.
- [ ] Existing story tests and DocC validation still run.

