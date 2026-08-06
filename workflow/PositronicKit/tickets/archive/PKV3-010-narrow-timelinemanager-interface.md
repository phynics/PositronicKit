# PKV3-010 — Narrow TimelineManager to lifecycle operations

**Priority:** P2
**Type:** Public interface deepening
**Depends on:** PKV3-002, PKV3-003, PKV3-004
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done (2026-07-13, PositronicKit `2b0a200`)

**Resolution:** `workspaceResolver` and `getToolManager(for:)` are no longer public on
`TimelineManager`. `getToolManager(for:)` moved into the same package-internal extension as
`getTurnBriefingBuilder(for:)`; hosts inject a `WorkspaceResolver` at construction rather than
reading it back off `TimelineManager`, and normal tool-execution flows go through
`TimelineDriver`/`ChatEngine` (same-module `ToolRouter` is unaffected, `@testable import` covers
existing tests). Both dependencies (PKV3-002's `WorkspaceResolver` injection, PKV3-004's
`TimelineToolRegistry` rename) were already on `main` when this ran. `swift build` clean,
`swift test` 968/968 (165 suites) at the time; re-verified at 963/963 (167 suites) after the
later Track 1 merge (net count shift is Track 1 test additions/removals, not a regression).

## Summary

Keep TimelineManager as the public lifecycle module while hiding injected resolution, context, and per-timeline tool internals.

## Implementation Requirements

- Retain lifecycle, attachment, pure lookup, and explicit touch operations.
- Do not expose WorkspaceResolver, context-builder access, or TimelineToolRegistry from TimelineManager.
- Route normal interaction through TimelineDriver and custom composition through top-level configuration.
- Do not reintroduce internal forwarding modules.

## Acceptance Criteria

- [ ] Public TimelineManager interface contains only lifecycle/attachment/query operations.
- [ ] TimelineDriver and configuration cover former legitimate caller needs.
- [ ] No public subordinate-manager leakage remains.
- [ ] Timeline behavior and tests remain intact.

