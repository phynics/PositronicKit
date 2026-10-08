---
status: accepted
---

# Runtime adapter tier for products that implement runtime protocols

## Context

AGENTS.md stated: "Providers and external integrations do not import the runtime." Two planned
products have to implement protocols that live in the `PositronicKit` target:

- durable storage → `TimelineRuntimeRepository`, `AgentStoreProtocol`, `WorkspaceStore`,
  `WorkspaceBindingRepository`, `RequestOriginStoreProtocol`;
- MCP → `WorkspaceProvider` / `WorkspaceToolProvider` / `WorkspaceFactory`.

`PKObservable` already imports `PositronicKit` to project runtime state outward, so the tier
exists informally but had no name, rule, or gate. Context: issue
[#257](https://github.com/phynics/PositronicKit/issues/257).

## Decision

**Name the runtime adapter tier.** The dependency order is:

`PKContracts` ← providers; `PKContracts`/`PKPrompt` ← `PositronicKit` ← **runtime adapters**
(`PKObservable`, planned `PKSQLiteStorage`, planned `PKMCP`).

A runtime adapter:

- may import `PositronicKit`, `PKContracts`, `PKPrompt`;
- must not import a provider product or another adapter;
- is never imported by `PositronicKit` or a provider;
- uses only public API, with no `@testable` and no `package` access, so it proves the public
  protocols are sufficient.

Third-party dependencies are allowed only inside an adapter's own target, so core products never
resolve them for linking. They still appear in `Package.resolved`; that is a recorded cost, not a
hidden one.

## Consequences

Durable-storage and MCP products have a named home with an enforced direction: they implement
host-facing runtime protocols without becoming part of the runtime. `PKObservable` is
retroactively classified as the first adapter. `Scripts/check-dependency-direction.sh` enforces
the tier: it fails if `PositronicKit` imports an adapter, if an adapter imports a provider, or
if an adapter uses `package`-level symbols.

## Rejected alternatives

- **Move the protocols and their record types (about 30 public types) into `PKContracts`.**
  Cleaner layering, but a large breaking move in the v7 window that pulls runtime vocabulary
  (Turn lifecycle, quarantine, bindings) into the runtime-neutral contracts.
