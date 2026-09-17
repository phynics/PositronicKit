---
status: accepted
---

# Swift 6.4 toolchain floor

Epic #192 adopts Swift 6.4. The package declares `swift-tools-version: 6.2`, while CI and the
Linux image pin 6.3.3. This ADR decides when PositronicKit may use 6.4 language and stdlib
features, and what happens to consumers still on a 6.3 toolchain. Issues #198 and #200 are blocked
on it, and ADR 0010 already assumes its answers.

## Context

`swift-tools-version` is a floor on every consumer, not a local build setting: SwiftPM refuses to
resolve a package whose tools version exceeds the toolchain in hand. Bumping it to 6.4 is
therefore a breaking change for an app on 6.3, even though no public API moves.

Two mechanisms exist to avoid that, and both introduce a second path. `#if compiler(>=6.4)` keeps
two source spellings of the same behavior. `#available` keeps two runtime spellings, for stdlib
API annotated above the deployment targets. AGENTS.md asks for one execution path over
compatibility layers, and ADR 0010 already rejected an `#available` fork of the terminal commit on
exactly that ground.

The compiler floor and the deployment targets are separate axes that this epic keeps conflating.
`swift-tools-version` decides which *syntax* compiles. `platforms:` decides which *stdlib API* is
callable. A 6.4 compiler does not make a stdlib symbol introduced in the Apple OS 27 releases
reachable from `.macOS(.v15)` / `.iOS(.v18)`.

`main` is the unreleased Next line and already carries breaking changes: the #156 naming cut, the
#176 generate fold, and the repository narrowing in ADR 0010. Another source-level break costs
consumers nothing extra if it ships in that same release.

## Decision

**The floor is 6.4, and it ships in the next breaking release.** `swift-tools-version` goes to 6.4
on `main`, in the same pull request that turns CI green on 6.4 under #193, so `main` never
declares a toolchain the gate does not run. It is not backported. A consumer on 6.3 stays on the
last tag of the current line, which keeps working and never receives 6.4 syntax. README,
`docs/Development.md`, and the CHANGELOG entry for that release name the floor.

**The deployment targets do not move, so stdlib API above them stays out of reach.**
`.macOS(.v15)` and `.iOS(.v18)` are unchanged. `withTaskCancellationShield` (SE-0504) is annotated
for the Apple OS 27 releases and is not back-deployed, so the package cannot call it whatever the
compiler floor is; ADR 0010 designs around its absence. `async` `defer` (SE-0493) is compiler
emitted over existing runtime entry points and carries no availability, so it is usable as soon as
the floor lands. The general rule follows from the split above: a 6.4 *language* feature is
available the moment the floor lands, and a 6.4 *stdlib* API is available only when its
`@available` annotation sits at or below macOS 15 / iOS 18. Each adopting ticket reads the
annotation in the shipped toolchain rather than assuming it. Raising a deployment target is a
separate decision that needs its own ADR.

**`#if compiler` and `#if swift` are not allowed in `Sources/` or `Tests/`.** Before the floor
lands, a guard ships two execution paths for one behavior and doubles what the gate must cover.
After it lands, the guard is a dead branch that no lane compiles. This holds for purely additive
syntax too: `anyAppleOS` under a compiler guard still leaves two availability spellings of the
same declaration. Version-specific manifests (`Package@swift-6.2.swift`) are excluded for the same
reason. The tools version is the single mechanism that states what this package compiles with.

`@available` and `#available` stay allowed, for platform capability only. Guarded code may expose
an optional capability that reports unsupported when the platform is older, which is what
`PKFoundationModelsProvider` already does. It may not carry a second implementation of a behavior
the runtime otherwise provides.

**CI keeps one toolchain lane per platform.** #193 runs 6.3.3 and 6.4 side by side while it
qualifies. The 6.3.3 lane and the 6.3.3 Linux image variant are deleted in the pull request that
bumps the tools version: the floor is the only supported toolchain, and a lane below it verifies a
configuration the package no longer declares. A newer toolchain gets a lane when a ticket adopts
it, not speculatively. `Scripts/doctor.sh` derives the required version from `Package.swift`, so
it follows the bump without an edit.

## Consequences

#198 and #200 unblock and may assume a 6.4 compiler. `anyAppleOS` in #200 is allowed syntax once
the floor lands, but it is still an availability change that widens the platforms a declaration is
available on and moves the public API baseline, so it needs the judgement in #200, not just the
floor. The `@diagnose` question in #200 is a separate policy about suppressing warnings and is not
settled here.

An app pinned to a 6.3 toolchain cannot take the next release. That is the cost this ADR accepts,
and it is recorded in the README requirements and under `CHANGELOG.md` > `Unreleased` when the
bump lands.

With one lane, a 6.3 regression goes unnoticed. That is intended: 6.3 is unsupported after the
bump, so there is nothing to regress against.

The `Package.swift` concurrency-gate comment stands as written. `NonisolatedNonsendingByDefault`
and `InferIsolatedConformances` stay enabled as upcoming features under the 6.4 tools version;
#193 confirms against the shipped toolchain whether 6.4 changes their default status, and the
comment is rewritten only if it does.

## Rejected alternatives

- **Bump before #193 qualifies.** It would declare support for a toolchain no gate runs, and the
  gate builds with `-warnings-as-errors`, where a new 6.4 diagnostic turns green code red.
- **Stay on 6.2 for this whole line.** The 6.2 floor is historical rather than chosen, and holding
  it blocks #198 and #200 while leaving the 6.4 diagnostics unverified until a later, larger jump.
- **`#if compiler(>=6.4)` guards.** Two paths per guarded site, two shapes to test, and no event
  ever removes them.
- **Version-specific manifests.** Two package graphs to keep in sync, selected silently by
  whichever toolchain resolves the package.
- **Raise the deployment targets to the Apple OS 27 releases to reach
  `withTaskCancellationShield`.** It charges every consumer on macOS 15 and iOS 18 for one stdlib
  function, and ADR 0010 solves that problem without it.
- **Keep a permanent 6.3 lane after the bump.** A lane is a support commitment; nothing in the
  package would be allowed to depend on it.
