# PKV3-004 — Name tool registration, execution, origin, and approval roles

**Priority:** P2
**Type:** Breaking API / terminology
**Depends on:** —
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done

## Summary

Rename tool roles so availability assembly, execution routing, origin, and approval policy each have one unambiguous term.

## Current Problem

- `ToolProviding` calls a tool contributor a provider, colliding with language-model providers.
- `TimelineToolManager` assembles/registers tools but its name does not distinguish this from execution.
- `ToolProvenance` and `ToolApprovalGate` name origin/policy indirectly.

## Implementation Requirements

- Rename `ToolProviding` → `ToolSource`, `provideTools()` → `tools()`, and `ToolProvenance` → `ToolOrigin`.
- Rename `TimelineToolManager` → `TimelineToolRegistry`.
- Rename `ToolApprovalGate` → `ToolApprovalPolicy`; retain `ToolRouter`.
- Preserve deterministic aggregation, source-origin stamping, approval defaults, and router execution/defer behavior.
- Migrate all package/downstream call sites, examples, docs, and tests.

## Acceptance Criteria

- [ ] Tool sources register into a TimelineToolRegistry with correct ToolOrigin labels.
- [ ] ToolApprovalPolicy still blocks permissioned calls by default.
- [ ] ToolRouter behavior is unchanged and clearly separate from registry behavior.
- [ ] No old public tool-role names remain.

