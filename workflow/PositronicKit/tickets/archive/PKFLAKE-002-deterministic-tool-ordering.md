# PKFLAKE-002 — Deterministic tool ordering in `TimelineToolManager`

**Priority:** P1
**Type:** Bug (nondeterministic prompt/request content)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done — added `sortToolsForOutput(_:)` with `(name, provenance.displayName)` key; regression test added; services-layer audit found no other unordered dictionary/set feeds to serialized LLM output. Merged `92cdea8`; `make verify` green (896 tests / 156 suites).

### Summary

`TimelineToolManager.getEnabledTools()` / `getAvailableTools()` build the tool array from
dictionary `.values`, so the order of tools serialized into LLM requests (and recorded in
prompt history) varies run-to-run for the same configuration. This defeats reproducible
prompt assembly and makes journal diffs noisy.

### Current Problem

`Sources/PositronicKit/Services/Timeline/TimelineToolManager.swift:154, 161, 173, 180` —
tools are appended from `workspaceTools.values` and `providerTools.values`
(`[String: AnyTool]` dictionaries) with undefined iteration order.

### Implementation Requirements

1. Sort tools deterministically before returning — stable key: tool name (and provenance
   as a tiebreaker if names can collide across providers).
2. Apply to both `getEnabledTools()` and `getAvailableTools()` (and any other `.values`
   aggregation in the file).
3. Add a test that registers several tools and asserts the returned order is stable and
   sorted across repeated calls.
4. Audit for other `Dictionary`/`Set` iteration feeding serialized LLM output in the
   Services layer; fix any found in the same change (note them in the resolution).

### Acceptance Criteria

- [ ] Tool arrays returned by `TimelineToolManager` are deterministic and documented.
- [ ] New ordering test in `PositronicKitTests`.
- [ ] `make verify` green.
