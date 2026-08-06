# PKAPI-008 — Grouped `RuntimeConfiguration` initializer doesn't expose `toolApprovalGate`

**Priority:** P2
**Type:** API design (gap)
**Depends on:** —
**Blocks:** —
**Triage:** wontfix
**Status:** Done (commit `97e6c68`, "feat(PKAPI-008): thread toolApprovalGate through grouped
PositronicKit initializers"). Confirmed 2026-07-09: `RuntimeConfiguration.toolApprovalGate` exists
(`PositronicKit+Configuration.swift:117`) and is threaded through both grouped inits
(`:77`/`:94` persistence-only form; `:167` persistence+runtime form). No further action.

### Summary

Confirmed. The "preferred" grouped initializers
(`Sources/PositronicKit/PositronicKit+Configuration.swift` —
`init(llmService:persistence:...)` at line ~65 and
`init(llmService:persistence:embeddingService:runtime:generationParameters:)` around line
135, taking `RuntimeConfiguration`) have no `toolApprovalGate` parameter anywhere —
`RuntimeConfiguration` (line 105) groups `workspaceCreator`, `sectionProviders`,
`runtimeToolPolicy`, `workspaceRoot`, `chatTurnPlugins`, `turnInspector`, but not the
approval gate. A host using either grouped initializer silently gets
`DenyAllToolApprovalGate` (the safe default, per the flat initializer at
`PositronicKit.swift:145`) with no way to inject a real approver without dropping down to
the 16-parameter flat `init`. Given the approval gate is called out as an important
safety mechanism (referenced as YAK-31 in the flat init's doc comment), the grouped path
silently blocking all permissioned tools is exactly the kind of gap a host integrating
via the "recommended" grouped API would hit without realizing why.

### Implementation Requirements

- [ ] Add `toolApprovalGate: any ToolApprovalGate = DenyAllToolApprovalGate()` to
      `RuntimeConfiguration`'s stored properties and `init`, and thread it through both
      grouped `PositronicKit.init` overloads in `PositronicKit+Configuration.swift` to the
      underlying flat `init`'s `toolApprovalGate:` parameter.
- [ ] Add/update tests exercising the grouped initializers with a non-default approval
      gate to confirm it's actually wired (not just accepted and dropped).

### Acceptance Criteria

- [ ] `RuntimeConfiguration` exposes `toolApprovalGate`; both grouped initializers thread
      it through correctly.
- [ ] Test confirms a custom `ToolApprovalGate` passed via the grouped path is honored at
      tool-execution time (not silently replaced by the default).
- [ ] `make verify` green; CHANGELOG updated (additive, non-breaking — default preserves
      existing `DenyAllToolApprovalGate` behavior).
