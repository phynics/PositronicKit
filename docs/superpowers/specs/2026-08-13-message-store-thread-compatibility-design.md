# Message Store Thread Compatibility Design

## Goal

Keep released v3 message-store conformers source-compatible while making the
thread-named message-store protocol the canonical PositronicKit API.

## Architecture

`ThreadMessageStoreProtocol` is the canonical protocol and uses `threadID` in
its query parameter labels. The released `MessageStoreProtocol` name remains a
deprecated legacy protocol with the original `timelineId` labels. A one-way
adapter converts a legacy existential into the canonical protocol; canonical
runtime internals and stored configuration properties never depend on the
legacy protocol.

`PersistenceConfiguration` exposes canonical initializers and
`fullyPersistent` APIs using `ThreadMessageStoreProtocol`. Deprecated overloads
accept `MessageStoreProtocol`, adapt it immediately, and emit the exact
existing timeline deprecation diagnostic:

> Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.

The transitional `TimelineMessageStoreProtocol` and
`LegacyTimelineMessageStoreAdapter` spellings remain source-compatible aliases
where they already exist, but are not used by canonical internals.

## Compatibility behavior

An existing type that declares `MessageStoreProtocol` conformance and
implements `fetchMessages(for timelineId:)`, `deleteMessages(for timelineId:)`,
and `fetchSnapshots(for timelineId:)` continues to compile. Passing that type
directly to `PositronicKit.PersistenceConfiguration(messageStore:)` selects a
deprecated compatibility overload, stores an adapter as the canonical
`ThreadMessageStoreProtocol`, and forwards all message operations unchanged.

## Verification

Tests include a legacy-only conformer (not a conformer to the canonical
protocol), direct configuration injection, adapter forwarding, and canonical
runtime behavior. Focused compatibility tests, a package build, and the
repository's documented verification gate must pass before commit.
