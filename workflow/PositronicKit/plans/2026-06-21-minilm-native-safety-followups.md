# MiniLM Native Safety Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the PKFastEmbed MiniLM boundary so Swift batch inputs stay valid, Rust validates returned embedding shapes before copying, and handle ownership is released on every failing initialization path.

**Architecture:** Keep the public Swift API and C ABI stable. Add a small injectable native-API shim in `MiniLMEmbedder` so Swift tests can deterministically inspect batch arguments and destroy counts, then refactor the Rust bridge around shape-validation helpers plus `catch_unwind` boundaries. The production paths should still flow through the same batch entry point and the same native model backend.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, Rust 2021, Cargo

## Global Constraints

- Keep `public func embed(_ texts: [String]) throws -> [[Float]]` unchanged.
- Keep the existing C ABI unchanged unless a native shape-status addition becomes unavoidable.
- Preserve one native batch call per nonempty Swift batch.
- Do not add public test-only API or process-global environment switches.
- Keep successful inference output ordering and dimensions unchanged.

---

### Task 1: Stabilize Swift batch UTF-8 storage

**Files:**
- Modify: `Packages/PKFastEmbed/Sources/PKFastEmbed/PKFastEmbed.swift`
- Modify: `Packages/PKFastEmbed/Tests/PKFastEmbedTests/PKFastEmbedTests.swift`

**Steps:**
- [ ] Add a failing test that captures batch input pointers, lengths, and call count for empty strings, composed/decomposed Unicode, emoji, repeated values, and embedded NUL bytes.
- [ ] Implement owned or temporary UTF-8 storage for `embed(_ texts:)` so pointer validity clearly encloses the native batch call.
- [ ] Add overflow-checked output allocation before invoking native batch inference.
- [ ] Keep the empty-batch fast path and preserve the single native batch invocation.

### Task 2: Make Swift handle ownership transactional

**Files:**
- Modify: `Packages/PKFastEmbed/Sources/PKFastEmbed/PKFastEmbed.swift`
- Modify: `Packages/PKFastEmbed/Tests/PKFastEmbedTests/PKFastEmbedTests.swift`

**Steps:**
- [ ] Add a failing test that injects a native dimensions failure after model creation and asserts the destroy count increments exactly once.
- [ ] Delay transferring the raw handle into `self.handle` until dimensions have been validated.
- [ ] Reject zero or otherwise invalid native dimensions before allocating output buffers.
- [ ] Keep `deinit` as the sole destroy path for successfully initialized instances.

### Task 3: Validate native shapes and contain panics

**Files:**
- Modify: `Packages/PKFastEmbed/native/src/lib.rs`
- Modify: `Packages/PKFastEmbed/Tests/PKFastEmbedTests/PKFastEmbedTests.swift`
- Modify only if ABI values change: `Packages/PKFastEmbed/native/include/pkfastembed.h`
- Keep synchronized if the header changes: `Packages/PKFastEmbed/Sources/CPKFastEmbed/include/pkfastembed.h`

**Steps:**
- [ ] Add Rust-internal helpers that validate single and batch embedding shapes before any output copy.
- [ ] Wrap exported inference paths with panic containment so no panic can cross the C ABI boundary.
- [ ] Replace unchecked batch-size multiplication with `checked_mul`.
- [ ] Add Rust unit tests for malformed single results, malformed batch results, and a controlled panic.
- [ ] Add Swift tests that still confirm valid single and batch embeddings and the existing invalid-UTF-8 / small-buffer cases.
