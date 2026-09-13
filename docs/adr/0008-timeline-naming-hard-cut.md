---
status: accepted
---

# Timeline naming hard cut

Issue #156 adopts **Timeline** as the domain term for a durable ordered history and Turn-admission
scope. `TimelineRecord` is the persisted metadata value, and `TimelineHandle` is the identity-bound
execution interface. The runtime exposes no bare `Timeline` value type.

The former `Thread` terminology collides with `Foundation.Thread` in ordinary Swift imports and
forces consumers toward selective `import struct` workarounds. The complete public and internal
Swift naming family therefore moves to Timeline in one hard cut: `ThreadHandle` becomes
`TimelineHandle`, repositories, controllers, messages, summaries, errors, and derived identifiers
follow the same vocabulary, and runtime tool Swift types are Timeline-based.

This decision supersedes the naming choice in ADRs 0001, 0003, 0004, and 0005 without discarding
their durability, authority-capture, workspace-binding, and hard-cut decisions. Their bodies remain
decision history. Existing encoded keys, storage paths, error domains, and model-facing tool
identifiers remain unchanged; renamed Swift properties use explicit `CodingKeys` where needed.

No compatibility aliases, dual reads, schema migration, fallback decoders, or parallel Thread entry
points are permitted. Historical ADR text and immutable release material may retain the old term,
but current Swift declarations, active documentation, and filenames use Timeline vocabulary.
