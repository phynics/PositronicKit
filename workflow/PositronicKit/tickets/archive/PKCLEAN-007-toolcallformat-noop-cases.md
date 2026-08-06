# PKCLEAN-007 — `ToolCallFormat.json`/`.xml` are user-visible no-ops: wire or remove

**Priority:** P2
**Type:** Bug / dead-code decision
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `84b0fc0`) — removed the dead `ToolCallFormat.json`/`.xml`
cases (`.openAI` is the only supported format); added a lenient `Codable` so on-disk configs with
stale `JSON`/`XML` raw values decode to `.openAI` instead of throwing; `ollamaDefaults.toolFormat`
`.json`→`.openAI`. PositronicKit-side only — Monad CLI/config migration deferred to `MON-PK-1`.
`swift test` green (924 tests / 158 suites, +1 regression test).

### Decision (2026-07-08) — **(a) Remove the dead option**

Non-OpenAI-style tool calling is not on the near-term roadmap, so `.json`/`.xml` are dead
options that mislead users today. Proceed with removal per option (a): drop the unused
cases (collapse toward `.openAI`-only if it is the sole reality), run the downstream grep
across all three consumers, and add the CHANGELOG semver note. Update
`ProviderConfiguration.ollamaDefaults` (currently defaults to the removed `.json`).

**Scope correction (2026-07-09):** the original decision text said "handle the persisted
value with a Monad GRDB column/migration" — **this is wrong.** `toolFormat` is persisted
via Monad's JSON-file-backed `ConfigurationStorage` (`LLMConfiguration`/
`ProviderConfiguration` are `Codable`, written to a config file), not a GRDB table. There is
no GRDB migration involved anywhere in this ticket. The real downstream risk is JSON decode
compatibility for old on-disk config files with a stale `"JSON"`/`"XML"` raw value — see
**MON-PK-1** (`workflow/Monad/tickets/`), filed to track that.

**Scope for this ticket (2026-07-09):** implement the PositronicKit-side removal only
(`ToolCallFormat` enum, `ProviderConfiguration`/`LLMConfiguration` call sites, any provider
code that reads it). Consider whether `ToolCallFormat` should keep a lenient/fallback
`Decodable` implementation (unrecognized raw value → `.openAI`) so any downstream JSON
config predating this change degrades gracefully instead of throwing — if you add that,
document it clearly since it directly informs MON-PK-1's scope. **Monad's CLI config UI
removal and config-migration handling are deliberately out of scope here** — tracked
separately as `MON-PK-1` in `workflow/Monad/tickets/`, to be picked up once this release is
cut and Monad's pin bumps. Do not edit Monad in this ticket.

### Summary

`ToolCallFormat` (`Sources/PKShared/SharedTypes/ToolCallFormat.swift`) has three cases
(`.openAI`, `.json`, `.xml`), is stored in `LLMConfiguration`/`ProviderConfiguration`,
persisted, and surfaced in Monad's CLI configuration screens — but **no code anywhere
reads `toolFormat` to branch behavior**. `.json` is even the default for Ollama
(`ProviderConfiguration.ollamaDefaults`) and is silently ignored by the Ollama client.
Users can select an option that does nothing.

Ready-for-human: this is a product decision — implement the formats or remove the
option.

### Options

- **(a) Remove** `.json`/`.xml` cases (or the whole enum if `.openAI` is the only
  reality). Requires: MonadCLI UI removal, Monad GRDB column/migration handling for the
  persisted value, downstream grep across all three consumers, CHANGELOG semver note.
- **(b) Wire** the formats into the providers that were supposed to honor them
  (presumably Ollama JSON tool-calling and an XML prompt-based fallback). Larger scope;
  only worth it if non-OpenAI-style tool calling is actually on the roadmap.

### Acceptance Criteria

- [ ] Decision recorded (a or b) with rationale.
- [ ] If (a): cases removed, Monad migration handled, all three consumers compile, no
      UI surface offers a dead option.
- [ ] If (b): each format observably changes provider request/parse behavior, with tests.
- [ ] `make verify` green; CHANGELOG updated.
