# PositronicKit Facade Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the public runtime facade to `PositronicKit` while preserving `PositronicKitCore` as a compatibility alias.

**Architecture:** Keep the module name `PositronicKit` unchanged. Rename the facade type, update the provider extensions and example helpers to target the new name, and leave a deprecated alias in place so existing adopters can migrate without a break.

**Tech Stack:** Swift 6.1, Swift Package Manager, `swift test`

## Global Constraints

- Keep the package/module name `PositronicKit`.
- Preserve source compatibility with `PositronicKitCore` via a public alias.
- Update public docs and examples to show `PositronicKit` as the primary entry point.
- Verify the package with targeted Swift tests after the rename.

---

### Task 1: Rename the Facade Symbol

**Files:**
- Modify: `Sources/PositronicKit/PositronicKitCore.swift`
- Modify: `Sources/PKOpenAIProvider/PKOpenAIProvider.swift`
- Modify: `Sources/PKOpenRouterProvider/PKOpenRouterProvider.swift`
- Modify: `Sources/PKOllamaProvider/PKOllamaProvider.swift`

**Interfaces:**
- Consumes: `LLMServiceProtocol`, `PersistenceConfiguration`, `RuntimeConfiguration`, `ChatTurnPlugin`
- Produces: `public struct PositronicKit`, `public typealias PositronicKitCore = PositronicKit`

- [ ] **Step 1: Rename the public type and its related extensions**

```swift
public struct PositronicKit: Sendable {
    // implementation unchanged
}

@available(*, deprecated, renamed: "PositronicKit")
public typealias PositronicKitCore = PositronicKit
```

- [ ] **Step 2: Update provider convenience extensions to extend `PositronicKit`**

```swift
public extension PositronicKit {
    init(openAIKey: String, model: String = "gpt-4o", generationParameters: GenerationParameters? = nil) {
        PKOpenAIProvider.register()
        let config = LLMConfiguration(modelName: model, apiKey: openAIKey, provider: .openAI)
        let llm = LLMService(configuration: config)
        self.init(llmService: llm, generationParameters: generationParameters)
    }
}
```

- [ ] **Step 3: Run the focused runtime setup story tests**

Run: `swift test --filter RuntimeSetupStoriesTests`
Expected: PASS after the rename is complete.

### Task 2: Update Public Documentation and Examples

**Files:**
- Modify: `README.md`
- Modify: `Sources/PositronicKit/README.md`
- Modify: `Sources/PositronicKit/docs/Usage.md`
- Modify: `Sources/PositronicKit/docs/Architecture.md`
- Modify: `Sources/PositronicKit/docs/Setup.md`
- Modify: `Sources/PositronicKit/PositronicKitCore.docc/PositronicKitCore.md`
- Modify: `Sources/PositronicKit/PositronicKitCore.docc/ArchitectureOverview.md`
- Modify: `Sources/PositronicKit/PositronicKitCore.docc/PersistenceLayer.md`
- Modify: `Sources/PositronicKitExamples/PositronicKitUsageExamples.swift`
- Modify: `Tests/PositronicKitTests/Stories/Setup/RuntimeSetupStoriesTests.swift`

**Interfaces:**
- Consumes: `PositronicKit`, `PersistenceConfiguration`, `RuntimeConfiguration`
- Produces: docs and examples that show the new facade name consistently

- [ ] **Step 1: Replace public-facing `PositronicKitCore` references with `PositronicKit`**

```swift
let chat = PositronicKit(llmService: myLLM)
let chat = PositronicKit(openAIKey: "sk-...")
let core = PositronicKit(ollamaModel: "llama3")
```

- [ ] **Step 2: Update comments and headings to match the new facade name**

```md
# PositronicKit
```

- [ ] **Step 3: Re-run the package tests that cover the updated examples**

Run: `swift test --filter ExampleUsageStoriesTests`
Expected: PASS.

