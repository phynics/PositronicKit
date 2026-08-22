# PositronicKit Agent Guide

PositronicKit is an embeddable Swift runtime for agentic application features. It combines a
transport-neutral runtime, prompt composition, provider-neutral contracts, and injectable
Workspace/persistence boundaries. The v4 effort is architecture convergence: domain vocabulary,
module boundaries, durable Turn semantics, and a smaller public API take priority over new
features.

## Source of truth

- Current shipped behavior: source, tests, `Package.swift`, and generated build artifacts.
- Durable architectural rationale: accepted [ADRs](docs/adr/).
- Canonical vocabulary: [CONTEXT-MAP.md](CONTEXT-MAP.md) and its linked glossaries.
- Planned work and historical delivery: GitHub Issues and PRs for
  [phynics/PositronicKit](https://github.com/phynics/PositronicKit).
- Published claims and release deltas: current guides, [README.md](README.md), and
  [CHANGELOG.md](CHANGELOG.md); tagged release documentation is immutable.
- Documentation or product changes: edit [docs/catalog.json](docs/catalog.json), then run
  `make verify-documentation`; generated navigation, landing, and `llms.txt` files are outputs.

When sources disagree, describe current behavior from code/tests and resolve intended v4
architecture through an ADR or the owning issue. Do not create local ticket archives or private
planning notes.

## v4 non-goals

This guide records the target vocabulary and accepted trade-offs; it does not claim that the full v4
runtime or broader new public API is implemented. Issue #63 establishes the `PKContracts` product
and its dependency boundary; later issues own the remaining runtime convergence. This guide also
does not add compatibility aliases or migrators, change provider/network/hosting behavior, or create
a replacement archive; those boundaries remain with their owning issues.

## Repository map

- `Sources/PositronicKit` — runtime domain and orchestration.
- `Sources/PKContracts` — runtime-neutral provider, tool, structured-output, and
  diagnostic contracts.
- `Sources/PKPrompt` — prompt IR, composition, assembly, rendering, and journaling.
- Provider targets — concrete provider adapters and convenience APIs.
- `Sources/PKObservable` — outward observation/UI integration.
- `Tests/PKTestSupport` — downstream-style test fixtures.
- `docs/Development.md` — contributor and platform setup.

## Canonical commands

Use the platform gate that matches the environment:

- macOS: `make verify`.
- Linux: `make agent-verify` inside the pinned Podman environment; use
  `make agent-test FILTER='…'` for focused tests.
- Preflight: `make doctor`.
- Product/example checks: `make verify-products`, `make verify-examples`, and
  `make verify-pktestsupport`.

Linux agents use the repository-owned Podman runner. Do not invoke host Swift or invent an ad hoc
container command; see [Development.md](docs/Development.md) for the supported environment and
the linker/model-cache gotchas.

## v4 convergence constraints

These are the target invariants for v4 work; an issue may not introduce a second vocabulary or
execution path while the migration is in progress:

- A Turn runs on a Thread. Managed execution derives Agent context from the Thread; a detached
  Thread uses the explicit direct path.
- Thread history is append-only, and one atomic Thread runtime repository owns Turn durability.
- Ordinary Workspaces are exclusively bound to Threads and execute through one deterministic
  dispatcher with process-local per-Workspace serialization.
- Execution authority is captured at Turn admission and is immutable while that Turn is active.
- Public consumers use shallow capability values and handles; managers, registries, pipeline
  topology, and model-round machinery remain implementation details.
- PKContracts imports no PositronicKit project target. Providers and external integrations do
  not import the runtime. PKUtilities is not a public grab-bag product.
- PromptJournal observes assembled prompt state; it is not semantic Thread history.

The full domain glossary and decision rationale live behind the [context map](CONTEXT-MAP.md) and
[ADRs](docs/adr/).

## Swift concurrency guardrails

Do not introduce a generic reference box to satisfy a `Sendable` diagnostic or mutate state from an
asynchronous closure. Choose actor isolation for asynchronous state, `Synchronization.Mutex<State>`
for synchronous state, `AsyncStream` for repeated signals, and structured task ownership for child
work. Any `@unchecked Sendable`, `NSLock`, stored continuation/task, or `Box`-named holder must be
documented in `docs/Concurrency/exception-manifest.md` and annotated inline at the site with
`// swiftlint:disable:this <rule> -- <reason>`; the global SwiftLint rules and
`make verify-concurrency-scan` enforce this policy.

## Contribution workflow

1. Find or create the owning GitHub issue before architectural or breaking work.
2. Keep one bounded behavior change per PR and preserve downstream seams.
3. Add deterministic tests and update current docs for public changes; update `CHANGELOG.md` under
   `Unreleased` for consumer-visible API changes.
4. Before closing an issue, complete its Delivery section with PR(s), merge commit(s), exact
   verification, docs/ADR impact, and follow-ups.
5. Keep tagged-release documentation immutable and separate from Next/main documentation.

Do not add a public product, protocol, plugin bus, compatibility alias, or migration path without
an owning issue and an independently justified consumer story.

## Pointers

- [Context map](CONTEXT-MAP.md)
- [Architecture guide](docs/Architecture.md)
- [Consumer setup](docs/Setup.md)
- [Contributor development guide](docs/Development.md)
- [Release guide](docs/Releasing.md)
- [v4 epic and work plan](https://github.com/phynics/PositronicKit/issues/61)
