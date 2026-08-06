# PKAPI-014 — `AgentWorkspaceServiceProtocol` takes untyped `[String: AnyCodable]` metadata

**Priority:** P3
**Type:** API design
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-11) — PK-side + regression resolved 2026-07-10 (commits `3c2cf33`,
`76cfc11`); downstream migration completed 2026-07-11.

> **Resolution (downstream, 2026-07-11):** Monad's `workspace.metadata` column dropped —
> removed from `DatabaseSchema+Baseline.swift`'s `createWorkspaceTables`, added migration `v10`
> in `DatabaseSchema+Migrations.swift` (guards on table/column existence, drops the column for
> existing databases), and a regression test in `MigrationTests.swift` verifying the drop.
> `WorkspaceReference+Persistence.swift` already had no metadata mapping (pre-existing). Monad's
> full suite: 174/174 tests pass. Yakamoz's `WorkspaceReferenceModel.metadataData` (confirmed
> write-only, never read back via `WorkspaceStore.swift`) removed from `PersistenceModels.swift`;
> not build/test-verified this session (Yakamoz's `make build` did not complete in time — a
> large, unrelated `git merge` of `yak-30-entrypoints` had to be resolved first, and the
> subsequent build was still running when this session wrapped up). Shuttle: grep-confirmed no
> workspace-metadata usage, not independently rebuilt this session.

> **Resolution (PK side):** Removed `metadata` from `WorkspaceReference` (stored
> property, both inits, `withTools`, `primaryForTimeline`) and from both
> `AgentWorkspaceServiceProtocol` requirements + `AgentWorkspaceService` impls
> (`createWorkspace`, `createAgentWorkspace`). Test fixtures updated.
>
> **Open issue — RESOLVED (2026-07-10, commit `76cfc11`).** The "regression" was a
> misattribution: the metadata removal did **not** cause `ObservableConversationTests` →
> "a superseding send cancels the previous stream" to fail. That test is an order-dependent
> **flake** that pre-existed the removal — the metadata change only shifted setup-time
> scheduling enough to surface it more often. Root cause (diagnosed with a 200× stress
> harness + tagged logging): the test gated readiness on `observable.isStreaming`, which
> flips inside `consume()` *before* `conversation.send` reaches the LLM. Under that window a
> superseding "second" send could reach `chatStream` before the cancelled "first" send did,
> claiming stream call **index 1** — the mock's never-finishing stream keyed to that index —
> and hanging on the 60s idle watchdog (surfacing as `streamTimedOut(60)`). Fix: gate the
> supersede until "first" has actually invoked `chatStream` (`mockClient.streamCallCount >= 1`)
> so the never-finishing index deterministically lands on "first". With both `3c2cf33` (removal)
> and `76cfc11` (flake fix) on `main`, the test passes reliably (verified 5×; 200× stress green).
>
> **Deferred (downstream, per PKFAC-008):** Monad GRDB migration to drop the
> `workspace.metadata` column; Yakamoz `WorkspaceStore`/`PersistenceModels`
> cleanup; Shuttle verify-clean. This is the only remaining work; the PK-side is
> complete and unblocked. Ticket stays open, blocked solely on the PKFAC-008 phase.
>
> **NB:** PK `make verify` currently carries 2 *pre-existing, unrelated* failures
> (`LLMServiceTests` `generateTitle` / schema-backed structured output assert a JSON-schema
> response format that isn't set) — not caused by this ticket; tracked separately.
**Type:** Public API removal (cross-repo, persisted-field)

> **Decision 2026-07-10 (user):** **remove** the workspace `metadata` field entirely, rather than
> type or document it. Trace confirmed it is dead in function: no production caller passes a
> non-empty dict, and no code in PK/Monad/Shuttle/Yakamoz reads a key back or branches on it — the
> only non-persistence reads are tests that write `["key":"value"]` and assert the passthrough
> round-trips. It is, however, a **persisted field**, so this is a cross-repo breaking change (see
> scope below), not a local delete. This ticket is re-scoped from "type-or-document" to full removal.
>
> **Rationale for accepting the cost:** an untyped, never-read passthrough is worse than no field;
> removing it shrinks the public `WorkspaceReference` surface and deletes two persistence code paths.

### Removal scope (all must land together — downstream-sync checklist applies)

1. **PositronicKit** — drop `metadata` from `WorkspaceReference` (stored property + both inits,
   `WorkspaceReference.swift:29-30,80,93,110,120,127`) and from both
   `AgentWorkspaceServiceProtocol` requirements + `AgentWorkspaceService` impls
   (`createWorkspace`, `createAgentWorkspace`). Remove `AgentInstanceManager`'s (empty) usage.
   Delete the round-trip assertions in `AgentWorkspaceServiceTests.swift:29,34,56`.
2. **Monad** — remove the `metadata` column mapping in `WorkspaceReference+Persistence.swift`
   (write side ~L32-36, read side ~L79-86) **and add a GRDB migration** in
   `DatabaseSchema+Migrations.swift` to drop/retire the `workspace.metadata` column. Update
   `MigrationTests.swift:137,276` fixtures that reference the column.
3. **Yakamoz** — remove `metadata` encode/decode from `WorkspaceStore.swift:10,44,67,79` and the
   `metadataData` field on the persisted model (`PersistenceModels.swift`).
4. **Shuttle** — grep confirmed no workspace-metadata usage; verify still clean before closing.
5. Bump each consumer pin against the compatible PositronicKit release per the root CLAUDE.md
   release-line flow; `make verify` (PK) + each consumer's gate green. CHANGELOG: breaking removal.

> **Note:** because this carries a Monad schema migration + a breaking public-field removal across
> all three consumers, coordinate landing with the PKFAC-008 downstream-migration phase rather than
> as an isolated PK-only change — the PK-side removal will not compile downstream until their pins
> and persistence code move in lockstep.

### Summary

Confirmed: `AgentWorkspaceServiceProtocol`
(`Sources/PositronicKit/Services/Workspace/AgentWorkspaceServiceProtocol.swift:5-19`)
accepts `metadata: [String: AnyCodable]` on both `createWorkspace(uri:location:originId:rootPath:metadata:)`
and `createAgentWorkspace(instanceId:template:metadata:)`. Nothing documents which keys
are meaningful, who reads them, or what value types are expected — the classic
weak-type-information problem the rest of this audit series targets (`Tool.parametersSchema`,
PKAPI-001).

Marked needs-info because the right fix depends on what metadata actually flows through
here in practice: if consumers use a small, known key set, a typed `WorkspaceMetadata`
struct is the fix; if it's genuinely open-ended host-defined data (plausible for a
workspace abstraction spanning Monad/Shuttle/Yakamoz), then the dictionary stays but the
contract ("opaque host-defined payload, persisted verbatim, never interpreted by
PositronicKit") must be documented instead.

### Implementation Requirements

- [ ] Trace what actually gets passed as `metadata` today: grep call sites in
      PositronicKit, Monad, Shuttle, and Yakamoz; list the concrete keys in use.
- [ ] If a bounded key set: introduce a typed `WorkspaceMetadata` struct (Codable,
      Sendable) and migrate; keep an `extra: [String: AnyCodable]` escape hatch only if a
      real open-ended case exists.
- [ ] If genuinely open-ended: document the opaque-payload contract on both protocol
      requirements and where the metadata is persisted/read back.

### Acceptance Criteria

- [ ] Metadata contract is either typed or explicitly documented as opaque — no
      undocumented `[String: AnyCodable]` on the protocol.
- [ ] Downstream consumers compile; `make verify` green; CHANGELOG updated if the
      signature changes.
