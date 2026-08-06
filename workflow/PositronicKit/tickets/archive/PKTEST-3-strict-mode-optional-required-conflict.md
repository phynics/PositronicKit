# PKTEST-3 — Strict-mode + optional-`required` conflict for nullable sidecar payloads

**Priority:** P3
**Type:** Bug (provider strict-schema compatibility)
**Depends on:** PKTEST-1 (investigation)
**Blocks:** none
**Status:** Done
**Resolution:** `SidecarSchemaComposer.containerSchema(for:)` now post-processes each directive's
object schema to list every property in `required` (sorted, for determinism) and adds
`additionalProperties: false` when `@Schemable` omits it. Previously an all-optional
`@Schemable` payload (e.g. `struct { let title: String? }`) emitted no `required` array, so
under the unconditional `strict: true` the provider silently degraded the schema and the model
freelanced off-schema keys (Yakamoz SID-3 root cause). The nullable union
`"type": ["string", "null"]` is preserved; `null` → `.declined` still works. Leaf-scalar
schemas (no `properties` key) pass through unchanged. PKTEST-1 investigation tests updated to
assert the fixed behavior. `make verify` green (900 tests / 157 suites). Commit `3164b00`.

### Summary

Surfaced by PKTEST-1's strict-mode investigation. `SidecarSchemaComposer.compose`
(`SidecarSchemaComposer.swift:72-77`) sets `strict: true` unconditionally on the composed
structured-output schema. When a directive's payload is an `@Schemable` struct whose only
field is an optional (`title: String?`), `@Schemable` correctly emits the nullable union
`"type": ["string", "null"]` but **omits the `required` array entirely** (all fields optional
→ no `required`). OpenAI's strict-JSON-schema mode requires every property to be listed in
`required`. The result: the provider silently degrades the schema and the model freelances
off-schema keys — in production (Yakamoz SID-3), the model returned `{"text": "..."}`
instead of `{"title": "..."}`.

This is the root cause behind Yakamoz SID-3's sidecar `title` directive never being applied.
Yakamoz's recover/single-string tolerance (SID-3 fix) remains the safety net; this ticket
fixes the provider-side schema so strict mode doesn't reject the optional payload.

### Current problem

- `SidecarSchemaComposer.compose` sets `strict: true` unconditionally (`SidecarSchemaComposer.swift:76`).
- `SidecarSchemaComposer.containerSchema(for:)` builds the inner container with
  `required: directives.map(\.name)` — but each directive's **own** schema (from `@Schemable`)
  controls its inner `required` array, which omits optionals.
- PKTEST-1's `strictModeWithOptionalPayloadField_omitsFromRequired` test pins this: the
  `title` property schema has `"type": ["string", "null"]` but no `required` array.
- PKTEST-1's `strictModeWithRequiredPayloadField_includesInRequired` test confirms the
  non-optional case (`title: String`) works correctly — `required` includes `"title"`.

### Implementation requirements

1. Decide between:
   - **(a)** Lower `strict` to `false` for directives whose payload schema has optional
     fields not in `required` (lowest risk, but loses strict-mode guarantees for those
     directives).
   - **(b)** Post-process the composed schema: when `strict: true`, ensure every property in
     every inner directive schema is listed in its `required` array (OpenAI strict mode
     requires this; nullable unions `["string","null"]` are already correct). This is more
     correct but touches the composer.
   - **(c)** Adjust the `@Schemable` usage or document that consumers should use non-optional
     fields with a sentinel for "declined" (breaks the `null` → `.declined` contract).
2. Whichever is chosen, **Yakamoz's SID-3 recover/single-string tolerance must remain the
   safety net** — don't rely solely on provider strictness.
3. Update the PKTEST-1 investigation tests to assert the fixed behavior.
4. Run the full `make verify` gate and verify downstream consumers (Monad, Shuttle, Yakamoz)
   still compile via local-path override.

### Acceptance criteria

- [ ] A sidecar directive with an optional `String?` payload field produces a schema that
      is valid under OpenAI strict mode (all properties in `required`).
- [ ] The nullable union `"type": ["string","null"]` is preserved (the field is still
      nullable; `null` → `.declined` still works).
- [ ] `make verify` green.
- [ ] CHANGELOG.md updated under `Unreleased`.
- [ ] Downstream consumers verified to compile (no public API change expected — this is a
      schema-composition fix, not an API change).
