# PositronicKit Agent Guide

PositronicKit is an embeddable Swift runtime for agentic application features. It combines a
transport-neutral runtime, prompt composition, provider-neutral contracts, and injectable
Workspace and persistence boundaries. Select work from current open issues and their dependencies.
Release-era epics describe historical delivery, not a standing priority over new work.

## Source of truth

- Current checkout behavior: source, tests, `Package.swift`, and generated build artifacts.
  For shipped behavior, inspect these at the release tag recorded in `docs/catalog.json`.
- Durable architectural rationale: accepted [ADRs](docs/adr/).
- Canonical vocabulary: [CONTEXT-MAP.md](CONTEXT-MAP.md) and its linked glossaries.
- Planned work and historical delivery: GitHub Issues and PRs for
  [phynics/PositronicKit](https://github.com/phynics/PositronicKit).
- Published claims and release deltas: current guides, [README.md](README.md), and
  [CHANGELOG.md](CHANGELOG.md); tagged release documentation is immutable.
- Documentation or product changes: update [docs/catalog.json](docs/catalog.json) when catalog
  metadata changes, then run `python3 Scripts/generate-doc-navigation.py` to regenerate navigation,
  landing pages, and `llms.txt`. Verify documentation with the platform gate below.

When sources disagree, describe current behavior from code and tests. Resolve intended changes
through an ADR or the owning issue. Do not create local ticket archives or private planning notes.

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
- Linux: run `make agent-verify` from the host checkout. It launches the pinned Podman environment.
  Use `make agent-test FILTER='…'` from the host for focused tests.
- Preflight: `make doctor`.
- macOS focused checks: `make verify-documentation`, `make verify-products`,
  `make verify-examples`, and `make verify-pktestsupport`. The Linux agent gate includes these checks.

Linux agents use the repository-owned Podman runner. Do not invoke host Swift or invent an ad hoc
container command; see [Development.md](docs/Development.md) for the supported environment and
the runner's locking, logs, prerequisites, and sandbox recovery. Documentation snippet checks invoke
Swift too. A successful syntax check does not prove API correctness. Verify changed example APIs
through `make verify-examples` on macOS or the Linux agent gate.

## Current architectural constraints

Before changing runtime ownership or module dependencies, read the [architecture guide](docs/Architecture.md)
and the relevant accepted ADR. Preserve these constraints unless the owning issue changes the contract:

- A Turn runs on a Thread. Managed execution derives Agent context from the Thread; a detached
  Thread uses the explicit direct path.
- Thread history is append-only, and one atomic Thread runtime repository owns Turn durability.
- Ordinary Workspaces are exclusively bound to Threads and execute through one deterministic
  dispatcher with process-local per-Workspace serialization.
- Execution authority is captured at Turn admission and is immutable while that Turn is active.
- Public consumers use shallow capability values and handles. Managers, registries, pipeline
  topology, and model-round machinery remain implementation details.
- PKContracts imports no PositronicKit project target. Provider adapters depend on PKContracts
  without importing the runtime. Observation and downstream runtime integrations may import
  PositronicKit. PKUtilities is an internal target, not a public product.
- PromptJournal observes assembled prompt state; it is not semantic Thread history.

The full domain glossary and decision rationale live behind the [context map](CONTEXT-MAP.md) and
[ADRs](docs/adr/). Older ADRs may refer to v4 because they record decisions made during that
release transition.

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
   For public API changes, inspect the platform symbol diff before recording a baseline with
   `make update-public-api-baseline` in the supported environment. Baseline filenames derive from
   `docs/catalog.json`'s `next.version`; follow [Releasing.md](docs/Releasing.md).
4. Before closing an issue, complete its Delivery section with PR(s), merge commit(s), exact
   verification, docs/ADR impact, and follow-ups.
5. Keep tagged-release documentation immutable and separate from Next/main documentation.
6. Before handoff, inspect the final diff and report the checks actually run, including skipped or
   blocked platform checks. Claim verification only for the code and platform checked.

Do not add a public product, protocol, plugin bus, compatibility alias, or migration path without
an owning issue and an independently justified consumer story.

## Pointers

- [Context map](CONTEXT-MAP.md)
- [Architecture guide](docs/Architecture.md)
- [Consumer setup](docs/Setup.md)
- [Contributor development guide](docs/Development.md)
- [Release guide](docs/Releasing.md)
- [Open issues and current work](https://github.com/phynics/PositronicKit/issues?q=is%3Aissue+is%3Aopen)
