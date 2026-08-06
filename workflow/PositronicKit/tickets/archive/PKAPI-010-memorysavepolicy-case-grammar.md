# PKAPI-010 — `MemorySavePolicy` mixes adjective and verb case names

**Priority:** P4
**Type:** API design / naming (cosmetic)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, commit `40f4b49`, merged into `main`) — `.preventSimilar(threshold:)`
→ `.deduplicating(threshold:)` (gerund/adjective form matching `.immediate`/`.deferred`'s grammar).
Single production call site (`TimelineArchiver.swift`) updated. Downstream grep: Monad references
the `MemorySavePolicy` type name in two places (`MemoryRepository.swift`,
`PersistenceServiceWrapper.swift`) but never pattern-matches `.preventSimilar`; Shuttle/Yakamoz
clean. No downstream migration required. `swift test` green (932 tests / 159 suites). CHANGELOG
updated (Breaking).

### Summary

Confirmed, minor: `Sources/PKShared/SharedTypes/PersistenceTypes.swift:4-8` —
```swift
public enum MemorySavePolicy: Sendable {
    case immediate
    case deferred
    case preventSimilar(threshold: Double)
}
```
`.immediate`/`.deferred` are adjectives (describing *when*); `.preventSimilar(threshold:)`
is an imperative verb phrase (describing *what it does*). Inconsistent grammar within one
enum reads oddly at call sites (`policy == .immediate` vs. reading `.preventSimilar` as an
action).

### Implementation Requirements

- [ ] Rename `.preventSimilar(threshold:)` to an adjective/noun form consistent with the
      other two cases, e.g. `.deduplicating(threshold:)` or `.deduplicated(threshold:)`.
- [ ] Grep for all switch/pattern-match sites across PositronicKit and downstream
      consumers.

### Acceptance Criteria

- [ ] All three `MemorySavePolicy` cases read as the same part of speech.
- [ ] Downstream grep clean across Monad/Shuttle/Yakamoz.
- [ ] `make verify` green; CHANGELOG updated (breaking rename).
