# PositronicKit v3 Vocabulary and Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release a coherent v3 public surface whose terminology names one role per concept and whose composition uses explicit injection rather than global registration.

**Architecture:** Deliver independent vertical slices for language-model composition, workspace extensibility, timeline interaction, tool roles, prompt preparation, compatibility cleanup, provider observability, module boundaries, and persistence seams. Each slice removes its old public vocabulary outright, migrates every in-package/downstream caller, and preserves behavior. A final release slice validates all three consumers against local overrides and documents source-breaking migrations.

**Tech Stack:** Swift 6.1, SwiftPM, Swift Testing, `@Observable`, PositronicKit, Monad, Shuttle, Yakamoz.

## Global Constraints

- This is the next PositronicKit major release; no deprecated compatibility aliases are retained.
- Audit and migrate Monad, Shuttle, and Yakamoz via local-path overrides before tagging.
- Do not recreate global provider registration or let users configure provider transport.
- Preserve native structured tool-call execution and the user-implementable workspace seam.
- Preserve PromptJournal cache/compaction behavior and TimelineManager's internal deep-module structure.
- Keep PKHYG-005 raw-text tool-call removal separate from this plan.

---

## Task 1: Replace global provider registration with direct LanguageModel injection

**Files:**
- Modify: `Sources/PKShared/SharedTypes/LLMProviderContracts.swift`
- Modify: `Sources/PositronicKit/PositronicKit+Configuration.swift`, `Sources/PositronicKit/PositronicKit.swift`
- Modify: provider target convenience initializers and every downstream composition root
- Test: `Tests/PositronicKitTests/Stories/Setup/**`, provider initialization tests, downstream local overrides

**Produces:** `LanguageModel` as the facade's single injected model requirement; no `ExternalLLMProviderRegistry`, `ProviderFactoryRequest`, or `register()` path.

- [ ] Add a failing facade test that constructs the kit from a fake `LanguageModel` and proves a turn streams without global registration.
- [ ] Define `LanguageModel: LLMStreamClient & LLMConfigStore & LLMUtilityClient`; keep the three capability protocols for internal/advanced seams.
- [ ] Rename public configuration fields and constructor labels from `llmService` to `languageModel`.
- [ ] Delete registry/factory-request types and migrate provider conveniences to direct client/factory injection owned by the host.
- [ ] Run targeted package tests, then Monad/Shuttle/Yakamoz local-override gates.
- [ ] Commit only provider-composition files and their migrations.

## Task 2: Make workspace roles explicit and inject WorkspaceResolver

**Files:**
- Modify: `Models/Workspace/WorkspaceProtocol.swift`, `Services/Database/WorkspacePersistenceProtocol.swift`
- Modify: `Services/Workspace/AgentWorkspaceService*.swift`, `WorkspaceManager*.swift`
- Modify: `Services/Timeline/TimelineManager*.swift`, `PositronicKit+Configuration.swift`
- Test: workspace manager/attachment tests plus a custom resolver contract test

**Produces:** `Workspace`, `WorkspaceFactory`, `WorkspaceStore`, `WorkspaceCatalog`, and `WorkspaceResolver`; TimelineManager receives a resolver rather than constructing one.

- [ ] Add a failing test using a host-defined resolver implementation and verify TimelineManager resolves a workspace without catalog/factory internals.
- [ ] Rename protocols/concrete adapters and their methods/docs according to the v3 glossary.
- [ ] Move default catalog/factory/resolver wiring into configuration/composition code.
- [ ] Delete TimelineManager's internal construction of the old service/manager graph.
- [ ] Migrate all three consumers and run focused workspace plus full package tests.
- [ ] Commit the workspace slice independently.

## Task 3: Replace Conversation with TimelineDriver

**Files:**
- Delete: `Sources/PositronicKit/Conversation.swift`
- Create: `Sources/PositronicKit/TimelineDriver.swift`
- Modify: `Sources/PKObservable/ObservableConversation.swift` and PKObservable tests
- Modify: stories, examples, DocC, downstream consumers, session-named tests/comments
- Test: TimelineDriver and TimelineController suites

**Produces:** a lightweight `TimelineDriver` with `timelineID`, `send`, and `cancel`; `TimelineController` owns SwiftUI projection.

- [ ] Add failing TimelineDriver tests for a pure open operation, streaming send, and cancellation delegation.
- [ ] Implement `PositronicKit.openTimeline(_:)` with no persistence I/O; retain `TimelineManager` for lifecycle operations.
- [ ] Replace `Conversation` and `ObservableConversation` with `TimelineDriver` and `TimelineController`.
- [ ] Rename non-provider session/conversation vocabulary across sources, tests, examples, and docs.
- [ ] Run package and consumer tests proving driver and controller behavior.
- [ ] Commit the timeline interaction slice independently.

## Task 4: Split tool registration, execution, origin, and approval vocabulary

**Files:**
- Modify: `Sources/PKShared/Tools/Tool.swift`, `ToolApprovalGate.swift`
- Modify: `Services/Timeline/TimelineToolManager.swift`, `Services/Tools/ToolRouter.swift`
- Modify: all tool tests, examples, and consumer integrations
- Test: timeline registry, router, origin, and approval-policy suites

**Produces:** `ToolSource`, `ToolOrigin`, `TimelineToolRegistry`, and `ToolApprovalPolicy`; `ToolRouter` remains unchanged.

- [ ] Add failing tests that register a ToolSource, verify ToolOrigin labeling, and deny an execution through ToolApprovalPolicy.
- [ ] Rename types, methods (`provideTools` to `tools`), and fields while preserving source aggregation and deterministic order.
- [ ] Rename TimelineToolManager and all call sites to TimelineToolRegistry; do not move tool routing into it.
- [ ] Rename ToolProvenance and ToolApprovalGate throughout PKShared, runtime, consumers, docs, and tests.
- [ ] Run package and downstream tool-path tests.
- [ ] Commit the tool slice independently.

## Task 5: Name turn briefing and prompt journaling roles

**Files:**
- Modify: `Services/Context/ContextManager.swift` and pipeline files
- Modify: `Services/Prompting/TimelinePromptHistory*.swift`, prompt inspection protocol/files
- Modify: PKPrompt/runtime tests, docs, examples, downstream inspectors
- Test: briefing, journal, and observer suites

**Produces:** `TurnBriefing`, `TurnBriefingBuilder`, `TimelinePromptJournals` (internal unless required), and `PromptObserver`/`PromptObserving`.

- [ ] Add a failing test asserting briefing output contains ranked memory/workspace material and is supplied to prompt assembly.
- [ ] Introduce the explicit TurnBriefing value and rename ContextManager to TurnBriefingBuilder.
- [ ] Rename registry/history ownership to TimelinePromptJournals without changing journal cache/compaction semantics.
- [ ] Rename PromptInspecting to PromptObserving and migrate inspector implementations, including Yakamoz.
- [ ] Run PKPrompt, runtime prompt-history, observer, and downstream inspection tests.
- [ ] Commit the prompt-preparation slice independently.

## Task 6 (PKV3-007): Remove compatibility and implementation-leak surface

**Files:**
- Modify: compatibility aliases, `LLMConfiguration`, `TimelineManager`, and public implementation-only declarations
- Modify: affected package tests, examples, docs, and consumer call sites
- Test: focused replacement-behavior tests plus package and consumer compile gates

**Produces:** only the v3 canonical API names and public symbols with demonstrated consumer value.

- [ ] Add failing compile/behavior tests for the canonical `timeline(id:)` and `touchTimeline(id:)` paths before deleting mutating `getTimeline(id:)`.
- [ ] Delete `CompactionThresholds`, `EmptySection`, the flat `LLMConfiguration` initializer and write-through proxies, and mutating `TimelineManager.getTimeline(id:)`.
- [ ] Migrate all package and consumer uses to `PromptJournalCompactionThresholds`, `EmptyPrompt`, provider-scoped configuration, `timeline(id:)`, and `touchTimeline(id:)`.
- [ ] Audit `StreamingParser`, `VectorMath`, and terminal-color formatting across all consumers; lower visibility only where the audit shows no external use.
- [ ] Keep `ToolOutputParser` untouched: PKHYG-005 remains its sole owner.
- [ ] Run focused and full package tests, then the relevant local-override consumer gates.
- [ ] Commit the compatibility slice independently.

## Task 7 (PKV3-008): Log provider capability variance and publish the matrix

**Files:**
- Modify: provider request/configuration paths and structured logging contracts
- Modify: provider contract tests and public provider documentation
- Test: provider behavior and payload-safety suites

**Produces:** one payload-safe structured warning per affected turn and a maintained provider capability matrix.

- [ ] Add failing provider contract tests for ignored/coerced tool options, response formats, and generation parameters.
- [ ] Emit at most one structured warning per turn containing provider/model identity, option category, reason, timeline ID, and turn index.
- [ ] Ensure warnings never contain prompt text, tool arguments, or response content while preserving provider request behavior.
- [ ] Publish the capability matrix and run all provider contract tests.
- [ ] Commit the observability slice independently.

## Task 8 (PKV3-009): Split PKUtilities from PKShared

**Files:**
- Modify: `Package.swift`, PKShared and new PKUtilities source layout, imports, and documentation
- Test: package dependency/build verification and affected package/consumer suites

**Produces:** public `PKUtilities` depending downward on `PKShared`, with no reverse dependency.

- [ ] Add a failing package-layout assertion covering the planned PKUtilities product and the absence of a PKShared-to-PKUtilities import.
- [ ] Create the public PKUtilities target/product and move observability, logging/redaction, async/pipeline helpers, and concrete filesystem tools into it.
- [ ] Retain contracts, errors, schemas, domain types, and tool contracts in PKShared; update all imports and target dependencies.
- [ ] Verify the dependency graph, package products, package tests, and downstream imports.
- [ ] Commit the module-split slice independently.

## Task 9 (PKV3-011): Make provider adapters leaf targets

**Depends on:** Tasks 1 and 8.

**Files:**
- Modify: provider target manifests/imports, LanguageModel contract location, and provider construction conveniences
- Test: provider-only build/test paths and core integration tests

**Produces:** provider adapters that depend on PKShared/PKUtilities and vendor SDKs, never on PositronicKit.

- [ ] Move LanguageModel and its narrow capability contracts into PKShared.
- [ ] Remove provider-target PositronicKit dependencies/imports and core-facing convenience extensions.
- [ ] Make concrete clients implement LanguageModel directly; retain provider transport as internal implementation.
- [ ] Verify every provider target builds/tests without PositronicKit, while designated integration tests retain coverage in core.
- [ ] Commit the leaf-target slice independently.

## Task 10 (PKV3-010): Narrow TimelineManager to lifecycle operations

**Depends on:** Tasks 2, 3, and 4.

**Files:**
- Modify: TimelineManager public interface, configuration, TimelineDriver call sites, and tests
- Test: lifecycle/attachment/query suites and API-surface checks

**Produces:** a deep public lifecycle module with normal interaction in TimelineDriver and composition in configuration.

- [ ] Add a focused public-surface test or API review checklist that distinguishes lifecycle operations from subordinate collaborators.
- [ ] Retain lifecycle, attachment, lookup, and explicit touch operations; hide WorkspaceResolver, briefing-builder, and TimelineToolRegistry access.
- [ ] Route valid interaction needs through TimelineDriver and custom composition needs through configuration without reintroducing forwarding services.
- [ ] Run TimelineManager and full package tests, then migrate affected consumers.
- [ ] Commit the interface-narrowing slice independently.

## Task 11 (PKV3-012): Capture explicit AnyTool identity and origin

**Depends on:** Task 4.

**Files:**
- Modify: Tool/AnyTool contracts, tool-source erasure, routing/events, and tests
- Test: identity/origin and routing regression suites

**Produces:** immutable ToolReference and ToolOrigin captured at erasure with no dynamic fallback.

- [ ] Add failing tests proving default identity is derived from `callName`, identity/origin remain stable after erasure, and routing preserves both.
- [ ] Add the Tool identity member with its default, then make AnyTool capture immutable ToolReference and ToolOrigin.
- [ ] Delete ToolReferenceProviding, its dynamic-cast fallback, and post-erasure origin mutation; make ToolSource apply origin during erasure.
- [ ] Run tool contract, routing, event, and consumer integration tests.
- [ ] Commit the identity slice independently.

## Task 12 (PKV3-013): Audit hypothetical persistence seams

**Files:**
- Modify or delete: AgentInstanceStoreProtocol, RequestOriginStoreProtocol, their adapters/mocks/tests, and audit evidence
- Test: retained-seam contract tests and package/consumer gates

**Produces:** no public persistence seam without a real consumer, concrete adapter, and contract test.

- [ ] Audit both protocols across PositronicKit, Monad, Shuttle, and Yakamoz; record consumer, adapter, and call-path evidence in PKV3-013.
- [ ] Delete every zero-consumer protocol with its mocks, tests, and docs.
- [ ] For each retained protocol, add or retain a concrete adapter and contract test that exercises its real consumer.
- [ ] Run package and affected consumer gates.
- [ ] Commit the persistence-seam result independently.

## Task 13 (PKV3-006): Complete the v3 migration and release gate

**Files:**
- Modify: `CHANGELOG.md`, `docs/Releasing.md`, public docs/examples, `README.md`
- Modify: all remaining Monad/Shuttle/Yakamoz call sites
- Test: package `make verify`; each consumer's documented gate under local override

**Consumes:** Tasks 1–12 (PKV3-001…005 and PKV3-007…013).
**Produces:** a source-breaking migration guide and release-qualified v3 tag candidate.

- [ ] Add a migration table for every removed/renamed public symbol and behavior change.
- [ ] Audit all three consumers for old terms and APIs; migrate every occurrence.
- [ ] Run PositronicKit `make verify` and verify products/examples.
- [ ] Run `swift test` in Monad and Shuttle and `make verify` in Yakamoz, using the local package override.
- [ ] Update release notes and follow `docs/Releasing.md` to tag/publish the major version only after every gate is green.
- [ ] Commit release documentation separately from feature slices.

## Plan self-review

- Every approved design area and every PKV3 ticket is represented by a distinct task with its own tests and commit.
- The final task owns cross-consumer migration and release verification, avoiding partial major-version claims.
- No task reintroduces prior rejected TimelineManager forwarding seams, provider registries, or raw-text tool inference.
