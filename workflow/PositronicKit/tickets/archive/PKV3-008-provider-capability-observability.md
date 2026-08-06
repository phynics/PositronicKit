# PKV3-008 — Log provider capability variance and publish the matrix

**Priority:** P2
**Type:** Observability / documentation
**Depends on:** —
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done (2026-07-13, PositronicKit `332341d`, merged to `main` via `347e554`)

**Resolution:** Added structured per-turn warnings when a provider ignores or coerces
tools/tool-choice/response-format/generation-parameters, correlated by provider/model identity,
option category, reason, timeline ID, and turn index — never prompt/tool-argument/response
content. Published `docs/ProviderCapabilityMatrix.md`. Provider contract tests cover retained
behavior and warning emission (see the updated provider composition/setup test commits in the
same track). Landed together with PKV3-001/009/011 as PKV3 Track 1; `swift build`/`swift test`
clean post-merge (963/963, 167 suites).

## Summary

Keep the common LanguageModel request surface while making ignored/coerced provider options observable and documented.

## Implementation Requirements

- Emit one structured warning per turn when a provider ignores or coerces tools, tool choice, response format, or generation parameters.
- Include provider/model identity, option category, reason, timeline ID, and turn index; never include prompts, tool arguments, or response content.
- Add provider contract tests for retained behavior and warning emission.
- Publish a concise provider capability matrix.

## Acceptance Criteria

- [ ] Unsupported options are never silently ignored.
- [ ] Warnings are correlated and payload-safe.
- [ ] Provider request behavior remains backward compatible.
- [ ] Capability matrix and tests cover every provider variance.

