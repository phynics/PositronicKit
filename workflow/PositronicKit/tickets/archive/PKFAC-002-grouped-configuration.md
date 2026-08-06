# PKFAC-002 — Grouped `Configuration` + generic convenience init; collapse the 16-parameter init

**Priority:** P2
**Type:** Public API
**Depends on:** PKFAC-001
**Blocks:** PKFAC-003
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, commit `e5147e4`)

Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) §4.

### Summary

Collapse today's ~16-parameter designated initializer (`PositronicKit.swift:129-207`) to ~2 core forms:

```swift
// Generic, provider-agnostic convenience.
public convenience init(llmService: any LLMServiceProtocol = UnconfiguredLLMService())

// One full form behind grouped config structs.
public init(configuration: PositronicKit.Configuration)
```

### Current problem

The flexible init takes 16 parameters (stores, embedding, workspace root/creator, section providers,
runtime tool policy, plugins, inspector, generation params, approval gate). It is unreadable and grows a
new parameter per feature.

**Re-scoped 2026-07-09** (verified against current source): the grouped `PersistenceConfiguration` /
`RuntimeConfiguration` structs already exist and are already feature-complete — `RuntimeConfiguration`
already carries `toolApprovalGate` (landed as **PKAPI-008**, commit `97e6c68` — that ticket is Done,
not "subsumed here" as originally written). The `init(llmService:persistence:runtime:...)` grouped
initializer already exists at `PositronicKit+Configuration.swift:143-169`. **What's actually left is
narrower than originally scoped:** collapse the flat 16-parameter `init` (`PositronicKit.swift:129-207`)
down so the grouped initializers are the only multi-parameter entry point, and fold the two grouped
inits (`persistence:` alone, and `persistence:runtime:`) into the single `PositronicKit.Configuration`
struct this ticket's title promises, rather than leaving three overlapping designated inits.

### Implementation Requirements

- [ ] Define `PositronicKit.Configuration` bundling `provider` (currently just `llmService`, kept generic
      per the design) / `persistence` (reuse existing `PersistenceConfiguration`) / `runtime` (reuse
      existing `RuntimeConfiguration`) / `generationParameters`. Exact field layout to be pinned in the
      implementation plan.
- [ ] Keep the generic `init(llmService:)` convenience (provider-agnostic) as the shallow entry —
      unchanged, already correct.
- [ ] Replace the flat 16-parameter `init` and the two existing grouped inits in
      `PositronicKit+Configuration.swift` with a single `init(configuration: PositronicKit.Configuration)`.
      Grep Monad/Shuttle/Yakamoz + `PositronicKitExamples` + tests for all three existing call-site shapes
      before removing.
- [ ] This work depends on **PKFAC-001** landing first (struct→class): rewriting init signatures on top of
      a class avoids reworking them twice.

### Acceptance Criteria

- [ ] Core exposes exactly the generic convenience + `init(configuration:)`; no 16-parameter flat init and
      no separate `persistence:`-only / `persistence:runtime:` grouped inits remain — one `Configuration`
      struct, one designated init.
- [ ] `toolApprovalGate` (already wired, PKAPI-008) continues to work unchanged through the new single init;
      existing regression test coverage still passes.
- [ ] `make verify` green.
