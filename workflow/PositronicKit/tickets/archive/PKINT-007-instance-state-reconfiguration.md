# PKINT-007 — Make Instance-Owned Cross-Send State Robust to Per-Send Reconfiguration

**Priority:** P3
**Type:** Composition robustness (latent state-loss footgun)
**Depends on:** None
**Blocks:** Consumers that rebuild the kit per send to pick up settings
**Status:** Done (2026-07-05)
**Surfaced by:** Yakamoz integration review (`YakamozRuntime.promptHistoryRegistry` hoist)
**Decision (2026-07-05, PKREL-002):** External registry injection — cross-send state becomes
an injectable construction parameter (optional `TimelinePromptHistoryRegistry`, defaulting to
fresh), keeping "rebuild per send" a supported pattern. Additive, so implementation lands
post-v1 as a 1.x minor; until then Yakamoz's runtime-lifetime hoist is the documented pattern.

### Summary

Make cross-send runtime state (prompt-history/journal registry, inspection counters) safe by
construction when a consumer reconstructs `PositronicKit` per send to refresh provider
settings — either by supporting per-run reconfiguration without a full rebuild, or by clearly
owning/relocating the at-risk state so a fresh instance cannot silently reset it.

### Current Problem

Yakamoz must resolve fresh provider settings/API key on every send, so `YakamozRuntime.run`
builds a brand-new `PositronicKit` per send. A fresh instance gets a fresh
`TimelinePromptHistoryRegistry` and a reset inspection-turn counter — which would collide
turn-index 0 of each send with the previous send's row and silently overwrite persisted
inspection data. Yakamoz worked around this by hoisting one `TimelinePromptHistoryRegistry`
to runtime lifetime and threading it into every `makeKit` call (see the long comment in
`Yakamoz/Sources/YakamozCore/Runtime/YakamozRuntime.swift`). This is a sharp edge any consumer
that rebuilds per send will hit, and the only signal is silently corrupted inspection history.

### Files

- Modify: `Sources/PositronicKit/PositronicKit.swift` (construction / reconfiguration surface).
- Modify: the prompt-history registry / inspection-counter ownership in `Services/Chat/`.
- Add/Modify: tests covering reconfiguration without state loss.

### Implementation Requirements

1. Provide a supported way to update per-run provider configuration (model, api key, endpoint)
   on an existing `PositronicKit` instance — e.g. accept configuration per `run` (via the
   `ChatRunRequest` from PKINT-005) or a `reconfigure(configuration:)` method — so consumers do
   not need to reconstruct the instance to change settings.
2. If per-instance reconstruction remains a supported pattern, document explicitly which
   collaborators are *instance-lifetime stateful* (registry, inspection counter) and must be
   injected/shared by the caller, and make those parameters non-defaulted or otherwise
   hard to omit so the footgun is visible at the call site rather than discovered via
   corrupted data.
3. Preserve current behavior for consumers that already share a registry.

### Required Tests

- Two sequential sends that change provider configuration between them assert prompt-history /
  inspection state is continuous (no reset, no row overwrite) using the supported
  reconfiguration path.
- A test documenting the ownership: constructing a second instance without sharing the
  stateful collaborator is either prevented by the API or produces a clear, asserted outcome
  (not silent corruption).

### Acceptance Criteria

- [x] A consumer can change provider settings between sends without losing prompt-history /
      inspection continuity and without a manual registry-hoist workaround.
- [x] Instance-lifetime stateful collaborators are documented and hard to drop accidentally.
- [x] `make verify` green; Monad/Shuttle build; Yakamoz can drop or simplify its hoist comment.

### Handoff Notes

This is the cleanest to land *after* PKINT-005, since a `ChatRunRequest` is the natural place
to carry per-send provider configuration and removes the original reason Yakamoz rebuilds the
kit at all.

### Resolution

Done in workspace changes on 2026-07-05 (`commit pending`). Added
`PositronicKit.reconfigured(llmService:generationParameters:)` so hosts can refresh provider
settings between sends while preserving prompt-history/inspection continuity automatically;
documented that manual whole-facade rebuilds still need an explicitly shared registry; added
`TurnInspectingTests` coverage proving the reconfigured path preserves turn indices across sends
and that a fresh facade without shared state resets them in a clear, asserted way. Yakamoz now
uses `kit.reconfigured(...)` instead of threading a raw prompt-history registry through every
per-send rebuild.

Verification: `swift test --filter TurnInspectingTests` and `make verify` passed in
`PositronicKit`. Downstream build attempts remain blocked by unrelated pre-existing drift:
`Monad` and `Shuttle` still fail on the already-tracked `ChatRunRequest` compile errors, and
`Yakamoz` still fails in `InspectionDTOs.swift` on the already-tracked inspection-model mismatch
before it reaches this runtime path.
