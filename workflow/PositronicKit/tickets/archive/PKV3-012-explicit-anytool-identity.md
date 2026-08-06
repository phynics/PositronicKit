# PKV3-012 — Make AnyTool identity and origin explicit

**Priority:** P2
**Type:** Tool contract cleanup
**Depends on:** PKV3-004
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done

## Summary

Capture immutable tool identity and origin at AnyTool erasure; delete dynamic identity discovery and post-erasure origin mutation.

## Implementation Requirements

- Add Tool identity to the Tool interface with a default derived from `callName`.
- Make AnyTool capture immutable ToolReference and ToolOrigin.
- Delete ToolReferenceProviding and its dynamic-cast fallback.
- Make ToolSource apply origin during erasure.
- Migrate routing, event, provenance/origin, and test code.

## Acceptance Criteria

- [ ] Every AnyTool has deterministic identity and origin without runtime casts.
- [ ] Simple Tool implementations retain a zero-boilerplate default identity.
- [ ] Tool routing/events preserve exact identity and origin.
- [ ] No mutable post-erasure origin path or ToolReferenceProviding remains.

