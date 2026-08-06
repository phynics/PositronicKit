# PositronicKit Open-Backlog Implementation Plan (2026-07-08)

Unified, importance-ordered execution plan across the 26 open tickets
(PKFLAKE / PKLOG / PKCOV / PKDEEP2 / PKCLEAN). The per-batch README sections give
local orders; this plan sequences them **globally** by importance and resolves the
cross-batch dependencies into a single pass.

**Guiding order:** correctness/races first → critical coverage → observability →
deepening refactors → cleanup/API retirements. Human-decision tickets are gated
explicitly so agent work never blocks on them.

Baseline: `make verify` green at 880 tests / 155 suites. Every phase must re-verify
with a non-decreasing executed-test count (zero-test-green is a known trap).

---

## Consistency fix (do first, trivial)

- **README count drift:** `tickets/README.md:3` says "22 open" but 26 ticket files
  exist (PKCLEAN-001…004 omitted from the count). Correct to **26 open**. Bundle this
  into the first ticket commit.

---

## Phase 1 — P1 correctness + the one real bug (parallelizable, all independent)

These are ship-blockers: nondeterminism and a user-visible misreport. All have
`Depends on: —` and touch disjoint files, so they can be dispatched to parallel
worktrees.

| Ticket | Why first | Notes |
|--------|-----------|-------|
| **PKFLAKE-001** | Fire-and-forget `preparationTask` race → services observably unconfigured at startup | `LLMService.swift:131,159`; no public API change |
| **PKFLAKE-002** | Nondeterministic tool ordering poisons prompt reproducibility + journal diffs | `TimelineToolManager.swift:154+`; also audit other `.values`/`Set` feeds |
| **PKDEEP2-002** | P2 by label but it's a *behavioral bug* Yakamoz's inspector renders — fix it here, and it **blocks PKDEEP2-003** | `TimelinePromptHistory.swift:102`; filter projection to `.semiStable` |
| **PKCOV-001** | P1 coverage gap: `WorkspaceManager` has no direct unit tests | Pure test add; safe anytime but pairs naturally with the correctness pass |

---

## Phase 2 — P2 concurrency / robustness

Remaining race + safety fixes. Independent; dispatch in parallel.

- **PKFLAKE-003** — `ToolTimeoutEnforcer` unstructured Tasks inside a checked continuation.
- **PKFLAKE-004** — `MiniLMEmbedder` `@unchecked Sendable` over a raw C handle.
- **PKFLAKE-005** — Remove `try?` swallowing on hydration + agent-message persistence.
- **PKFLAKE-006** — Deflake time-dependent tests; inject a clock into `ContextRanker`.

---

## Phase 3 — Critical + remaining coverage

- **PKCOV-002** — Provider initialization contract tests.
- **PKCOV-003** — Embeddings test expansion (coordinate loosely with PKFLAKE-004; land 004 first if touching the same embedder).
- **PKCOV-004** (P3) — `ToolApprovalGate` enforcement coverage across filesystem tools.

---

## Phase 4 — Observability (auditability of the loop)

- **PKLOG-002** — Stream-failure context in `LLMStreamingStage` (standalone).
- **PKLOG-001** — Journal-update + turn-inspection-skip logging. **Sequencing:** touches
  `TurnPreparer`/`TurnLoopController`, which **PKDEEP2-001 folds away**. Do PKLOG-001
  **before** PKDEEP2-001 (add logs at current sites), or fold first then add logs in the
  new extension files. Pick one and note it — do not run them concurrently.
- **PKLOG-003** (P3) — Batch-level tool-routing telemetry in `ToolRouter`.
- **PKLOG-004** (P3, ready-for-human) — Structured log metadata + PKError consistency.
  Needs a human call on the metadata schema before agent work.

---

## Phase 5 — Deepening refactors (internal, larger blast radius)

- **PKDEEP2-001** — Fold `TurnPreparer` + `TurnLoopController` into `ChatEngine`
  extension files (PKDEEP-002 pattern). Internal-only, zero downstream refs.
  **Coordinate with PKLOG-001** (see Phase 4).
- **PKDEEP2-003** (ready-for-human) — Share compaction-pressure + section-fingerprint core
  between the two prompt histories. **Gate: human must pick fingerprint-input policy
  (a/b/c; investigation recommends (a))** — (a) changes observable runtime diff output.
  **Depends on PKDEEP2-002** (Phase 1). This must land **before** PKCLEAN-002.

---

## Phase 6a — Cleanup: mechanical, agent-ready, independent

Standalone splits and dead-code removals with no gates and no ordering dependency on
anything else in Phase 5/6 — dispatch in parallel worktrees.

- **PKCLEAN-001** — Split `OpenRouterClient.swift` model layer out (standalone).
- **PKCLEAN-005** — Delete unused `OpenAIEmbeddingService`.
- **PKCLEAN-006** — Remove `PipelineBuilder`, throwing `assertUniqueIDs`, ID-validation wrappers.
- **PKCLEAN-008** — Dedup structured-output adapters; inline `MessageParser`; `HealthCheckable` cleanup.
- **PKCLEAN-009** — Build-surface housekeeping (Examples test dep, `PKFastEmbed` product).

---

## Phase 6b — Cleanup: ordered / gated retirements

Save for last so they rebase over Phase 5's refactors instead of colliding with them.
**Update (2026-07-09): all four gates are now cleared** — PKDEEP2-003 landed (Phase 5),
PKCLEAN-004's downstream grep is clean, and PKCLEAN-007/PKCLEAN-003 already carry recorded
decisions (dated 2026-07-08) and are `Triage: ready-for-agent`. Nothing in this phase is
still waiting on a human call; sequencing (not gating) is the only remaining constraint.

- **PKCLEAN-002** — Split `TimelinePromptHistory.swift` value types. Land after PKDEEP2-003
  (done) — narrow to the types PKDEEP2-003 left intact.
- **PKCLEAN-004** — Retire deprecated `AnyTool` string-provenance init. Downstream grep
  (2026-07-09): two Yakamoz call sites pass `provenance:` as `ToolProvenance` (the current
  overload), not `String?` — zero real callers of the deprecated initializer. Ready to
  implement.
- **PKCLEAN-007** — `ToolCallFormat.json`/`.xml` no-ops. **Decision recorded (a) remove**:
  drop the dead cases, remove MonadCLI config UI, handle the persisted value via a Monad
  GRDB migration, downstream grep, CHANGELOG semver note.
- **PKCLEAN-003** — Retire deprecated `LLMServiceProtocol` composite. **Decision recorded
  (a) migrate facade**: move the facade off the composite onto the narrow protocols, delete
  the composite, run the downstream-sync checklist, bump consumer pins per the release-line
  upgrade flow. Public API change — needs a PositronicKit release cut before consumer pins
  bump.

---

## Phase 7 — User architecture-concerns pass (PKCLEAN-011…013)

Filed 2026-07-09 from a user-driven review of five architecture concerns. Two of the
three (`HealthCheckable`, `ToolOutputParser`) turned out fully dead and were folded into
PKCLEAN-008/010 above — only the remaining three real, narrower concerns are here.
**Update (2026-07-09): all three design decisions are now resolved** (two via Opus design
passes at the user's request); full decisions live on the ticket files. All three are
`ready-for-agent`.

- **PKCLEAN-013** — Expose tools grouped by workspace instead of a flat list + provenance
  tag. Standalone, ready-for-agent. **Coordinate with PKAPI-001** (Phase 8) — both touch
  the `Tool`/`AnyTool` surface; land PKAPI-001 first (see Phase 8 note).
- **PKCLEAN-011** — Clarify the `TurnInspecting`/`ChatTurnPlugin` seam. **Decision: keep
  two protocols, docs-only.** The two hooks fire in *different phases* (compose-time,
  pre-LLM, read-only observation vs. complete-time, post-LLM, read-write turn-driving), so
  they must not merge and `TurnInspecting` must not be renamed. Correct the ticket's stale
  "both fire around completion" premise in the resolution note. See the ticket for the full
  decision + exact docstrings.
- **PKCLEAN-012** — Facade doesn't bootstrap a runtime. **Decision: build a
  progressive-disclosure bootstrap ladder** (Tier 0 `standalone(...) -> Bootstrapped`,
  Tier 1 `bootstrapTimeline()`/`bootstrapAgent()`, Tier 2 the existing wide init), all
  additive, sharing `TimelineManager.createTimeline` as the single seam; the facade now
  owns its own `AgentInstanceManager` (option a — collapses Monad's post-construction
  rebind); agent bootstrap is in v1; downstream migration deferred. See the ticket for the
  full API surface + ownership rationale.

---

## Phase 8 — Swift API Design Guidelines audit (PKAPI series)

14 tickets across two discovery sweeps (2026-07-09), all touching `PositronicKit`'s
public surface. Every closing ticket needs the standard downstream grep (Monad, Shuttle,
Yakamoz) before archiving — same rule as PKCLEAN-002/003/004/007. 11 of 14 are
ready-for-agent; PKAPI-002/006/014 are needs-info and gated (see below). One review
finding ("1d" — `Prompt.makePromptNode()`) was already investigated and rejected: the
default implementation walks `body` and lowers to the IR automatically, so no ticket was
filed for it.

**Suggested order** (per the README's own sequencing, with the second sweep folded in):

1. **PKAPI-001** — Unify tool-argument type (`Any` → `AnyCodable`); type
   `parametersSchema`; fix `canExecute` doc. Touches the most call sites (the `Tool`
   protocol) — land first so later tool-surface work (PKCLEAN-013 above, PKCLEAN-004)
   rebases over it rather than the reverse.
2. **PKAPI-004** — `ChatEvent` ergonomics: `.failed`/`.failure` collision, double-nesting,
   hardcoded `.blocked` set. Also high-touch; independent of the tool surface, so it can
   follow immediately.
3. **PKAPI-003** — Unify `think`/`thinking`/`reasoning` terminology across message/event
   types.
4. **PKAPI-007** / **PKAPI-008** — Provider/LLM parameter ergonomics (unlabeled `Factory`
   tuple, ambiguous booleans, silent write-through setters) + grouped-init missing
   `toolApprovalGate`. Independent of each other; parallelizable.
5. **PKAPI-012** / **PKAPI-013** (second sweep) — session/timeline terminology drift;
   undocumented `dryRun` booleans + `reset(hard:)` call-site clarity. Small, standalone;
   parallelizable with each other and with step 4.
6. **PKAPI-005** / **PKAPI-009** — Facade fluent naming (`addPlugin`/`addStage` verb form,
   `getTimeline` side effect); `formatToolsForPrompt(_:)` → a method on `[AnyTool]`.
   Smaller renames, parallelizable.
7. **PKAPI-010** / **PKAPI-011** — `MemorySavePolicy` case-grammar fix; missing/thin doc
   comments (extended inventory, folds in the second sweep's docs findings). Cosmetic,
   no rush — safe to batch together or defer past everything else in this phase.

**Gated (needs human triage before agent work):**
- **PKAPI-002** — `Tool.id`/`Tool.name` → `LLMToolDefinition.name` mapping clarity.
- **PKAPI-006** — `AnyPrompt` naming (suggests type erasure, is actually a container/group).
- **PKAPI-014** — `AgentWorkspaceServiceProtocol` untyped `[String: AnyCodable]` metadata.

---

## Needs human input — not yet resolved

Distinct from the RESOLVED gates below: these surfaced after 2026-07-08 and have no
decision recorded yet. Agent work on the tickets they gate should wait.

**PKCLEAN-011 and PKCLEAN-012 resolved 2026-07-09** (Phase 7 decisions — see that section
and the ticket files). Remaining open questions are all Phase 8 PKAPI items:

1. **PKAPI-002** — rename `Tool.id`/`Tool.name`, or just document the wire-mapping to
   `LLMToolDefinition.name` more clearly?
2. **PKAPI-006** — rename `AnyPrompt`, or document that it's a container/group rather than
   a type-erasing wrapper?
3. **PKAPI-014** — introduce a typed workspace-metadata model, or document the untyped
   `[String: AnyCodable]` contract as intentional?

---

## Human-decision gates — RESOLVED 2026-07-08 (all now ready-for-agent)

1. **PKDEEP2-003** — fingerprint policy: **(b) text-only everywhere.** Provider never sees
   `estimatedTokens`/`type`; token drift with identical text is an estimator artifact, not
   real cache invalidation. Adopt PKPrompt to the runtime's text-only hash; fold only
   content-bearing message fields (role/`isSummary`/`think`) if not already in rendered text.
2. **PKCLEAN-007** — **(a) remove** `.json`/`.xml`; non-OpenAI tool calling not on roadmap.
   Needs Monad GRDB migration + CLI UI removal + `ollamaDefaults` fix.
3. **PKCLEAN-003** — **(a) migrate facade** to narrow protocols, delete composite. Public
   API change → release + consumer pin bumps.
4. **PKLOG-004** — `LogKeys` namespace, camelCase keys (`timelineID`, `sendID`, `turnIndex`,
   `toolName`, `provider`, `stage`, `errorCode`); align to existing metadata before adding.

## Downstream-sync reminders

PKDEEP2-003, PKCLEAN-002/003/004/007 touch public API or persisted fields → grep
**all three** consumers (Monad, Shuttle, Yakamoz) before closing; PKCLEAN-007 removal
additionally needs a Monad GRDB migration (per root `CLAUDE.md` checklist).

All 14 PKAPI tickets (Phase 8) touch `PositronicKit`'s public surface → grep all three
consumers before closing each one, same rule. PKAPI-001 (tool-argument type unification)
and PKAPI-004 (`ChatEvent` ergonomics) are the highest-touch and most likely to need a
consumer-side follow-up call site change; check both explicitly rather than assuming a
clean grep.
</content>
</invoke>
