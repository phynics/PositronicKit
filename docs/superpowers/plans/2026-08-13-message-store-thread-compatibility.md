# Message Store Thread Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve v3 `MessageStoreProtocol` conformers with `timelineId` signatures while making `ThreadMessageStoreProtocol` canonical.

**Architecture:** Rename the canonical protocol surface to `ThreadMessageStoreProtocol`, restore `MessageStoreProtocol` as the deprecated legacy surface, and bridge legacy values through a one-way adapter. Canonical configuration properties and internals use only the thread-named existential; deprecated overloads perform adaptation at the boundary.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, PositronicKit persistence protocols, `make agent-test`, `make agent-verify`.

## Global Constraints

- Preserve the exact diagnostic: `Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.`
- Existing source conformance to `MessageStoreProtocol` with `timelineId` labels must compile.
- Canonical `ThreadMessageStoreProtocol` uses `threadID` labels and remains the primary internal seam.
- Tests must prove a legacy-only conformer can be injected directly into `PositronicKit.PersistenceConfiguration`.
- On macOS use native Swift verification; Linux gates must run through the repository's documented `make agent-*` targets.

---

### Task 1: Add the failing legacy-only compatibility test

**Files:**
- Modify: `Tests/PositronicKitTests/ThreadAPICompatibilityTests.swift`

**Interfaces:**
- Consumes the existing `PositronicKit.PersistenceConfiguration` and message-store APIs.
- Produces a test that requires a legacy `MessageStoreProtocol` existential to be accepted directly by configuration.

- [ ] **Step 1: Add a legacy-only conformer and direct configuration test**

  Define an actor conforming only to deprecated `MessageStoreProtocol`, with
  the `timelineId` labels. Construct
  `PersistenceConfiguration(messageStore: legacyStore, threadPersistence: ...)`
  and assert that `configuration.messageStore` forwards save/fetch/delete.
  Keep the test function and helper conformer marked with the existing
  intentional-deprecation annotation.

- [ ] **Step 2: Run the focused test to verify RED**

  Run:

  ```bash
  swift test --filter ThreadAPICompatibilityTests
  ```

  Expected: compilation fails because the legacy-only `MessageStoreProtocol`
  conformer does not satisfy the current canonical `messageStore` parameter.

### Task 2: Implement the canonical/legacy protocol boundary

**Files:**
- Modify: `Sources/PositronicKit/Services/Database/MessageStoreProtocol.swift`
- Modify: `Sources/PositronicKit/Compatibility/TimelineAPICompatibility.swift`
- Modify: `Sources/PositronicKit/Services/Storage/InMemoryMessageStore.swift`
- Modify: all canonical Swift files found by `rg 'MessageStoreProtocol' Sources --glob '*.swift'`

**Interfaces:**
- Produces public `ThreadMessageStoreProtocol` with `threadID` labels.
- Produces deprecated public `MessageStoreProtocol` with `timelineId` labels.
- Produces a one-way legacy-to-canonical adapter and preserves current transitional adapter aliases.

- [ ] **Step 1: Rename the canonical protocol declaration and update canonical conformances**

  Move the current thread-labeled requirements to
  `ThreadMessageStoreProtocol`, update its default `saveMessageIfAbsent`
  extension, and update in-memory storage, composite persistence, runtime
  services, and all canonical existential properties to use the new name.

- [ ] **Step 2: Restore the legacy protocol name and adapter**

  Declare deprecated `MessageStoreProtocol` with the v3 `timelineId`
  requirements and the exact diagnostic. Make the adapter accept
  `any MessageStoreProtocol` and conform to `ThreadMessageStoreProtocol`.
  Preserve `TimelineMessageStoreProtocol` and
  `LegacyTimelineMessageStoreAdapter` as deprecated compatibility aliases if
  they are already public in this branch.

- [ ] **Step 3: Run the focused test to verify GREEN**

  Run:

  ```bash
  swift test --filter ThreadAPICompatibilityTests
  ```

  Expected: all compatibility tests pass, including direct legacy injection.

### Task 3: Add deprecated configuration injection overloads

**Files:**
- Modify: `Sources/PositronicKit/PositronicKit+Configuration.swift`
- Modify: `Tests/PositronicKitTests/ThreadAPICompatibilityTests.swift`

**Interfaces:**
- Canonical `PersistenceConfiguration.messageStore` is `any ThreadMessageStoreProtocol`.
- Canonical initializers and `fullyPersistent` use `ThreadMessageStoreProtocol`.
- Deprecated overloads accept `any MessageStoreProtocol` and store an adapter.

- [ ] **Step 1: Change canonical configuration signatures**

  Update the primary optional-store initializer and canonical
  `fullyPersistent` overload to use `ThreadMessageStoreProtocol`; preserve all
  defaults and other store types.

- [ ] **Step 2: Add legacy overloads with exact diagnostics**

  Add `_disfavoredOverload` deprecated initializers/overloads for
  `messageStore: any MessageStoreProtocol`. They must call the adapter and
  then the canonical construction path without changing the public canonical
  property type.

- [ ] **Step 3: Assert canonical storage and forwarding**

  Extend the compatibility test to verify that the configuration's message
  store is usable as `ThreadMessageStoreProtocol` and forwards through the
  original actor's `timelineId` methods.

- [ ] **Step 4: Run focused tests**

  Run:

  ```bash
  swift test --filter ThreadAPICompatibilityTests
  ```

  Expected: PASS with no non-intentional diagnostics.

### Task 4: Build and verify the package

**Files:**
- No additional source files; inspect all modified files and generated build output only.

- [ ] **Step 1: Run the package build**

  ```bash
  swift build
  ```

- [ ] **Step 2: Run the canonical repository gate**

  ```bash
  make verify
  ```

  On Linux, use `make agent-verify` instead, per repository instructions.

- [ ] **Step 3: Review the diff and confirm no canonical `MessageStoreProtocol` references remain**

  ```bash
  rg -n 'MessageStoreProtocol' Sources Tests --glob '*.swift'
  git diff --check
  git status --short
  ```

### Task 5: Commit the completed compatibility fix

**Files:**
- Stage the design note, implementation plan, source changes, and tests.

- [ ] **Step 1: Commit**

  ```bash
  git add docs/superpowers/specs/2026-08-13-message-store-thread-compatibility-design.md docs/superpowers/plans/2026-08-13-message-store-thread-compatibility.md Sources/PositronicKit/Services/Database/MessageStoreProtocol.swift Sources/PositronicKit/Compatibility/TimelineAPICompatibility.swift Sources/PositronicKit/PositronicKit+Configuration.swift Sources/PositronicKit/Services/Storage/InMemoryMessageStore.swift Tests/PositronicKitTests/ThreadAPICompatibilityTests.swift
  git commit -m "fix: preserve legacy message store injection"
  ```
