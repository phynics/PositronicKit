# PositronicKit Release-Hygiene Tranche Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate manifest/build/test/layout drift and remove raw-text tool-call inference while preserving native provider tool execution.

**Architecture:** `Package.swift` remains the source of truth for public products; a small Swift script projects its JSON description into Makefile product lanes. Test targets become owners of their production module coverage, while test fixtures remain an internal test-only target. Tool execution accepts only provider-native structured call deltas after a consumer audit confirms no fallback dependency.

**Tech Stack:** Swift 6.1, SwiftPM, GNU/BSD make, Foundation JSON decoding, Swift Testing, Bash.

## Global Constraints

- Work in `PositronicKit/`; workflow artifacts live in `workflow/PositronicKit/`.
- Preserve the existing `PositronicKitExamples` behavioral-story dependency in `PositronicKitTests`.
- `PKTestSupport` is test infrastructure, not a public product.
- Do not add `jq`, Python, or another host tool as a new build prerequisite.
- `verify-products` builds library products only; `verify-examples` owns the executable.
- Raw-text tool-call parsing must be removed only after Monad, Shuttle, and Yakamoz usage audits are recorded.
- Native provider structured tool calls and `ToolApprovalGate` behavior remain unchanged.
- Update `CHANGELOG.md` for the raw-text tool-calling behavior change.

---

## File map

| File | Responsibility |
|---|---|
| `PositronicKit/Scripts/list-library-products.swift` | Decode `swift package describe --type json` and print declared library product names. |
| `PositronicKit/Makefile` | Define manifest-driven verification lanes and compose the macOS gate. |
| `PositronicKit/Package.swift` | Remove `PKTestSupport` from products; introduce module-owned test targets and dependencies. |
| `PositronicKit/Tests/PK*ProviderTests/**` | Provider adapter test ownership. |
| `PositronicKit/Tests/PKSharedTests/**` | PKShared contract/model test ownership. |
| `PositronicKit/Sources/PositronicKit/README.md` | Remove stale duplicated target documentation or reduce to a one-line ownership pointer. |
| `PositronicKit/docs/index.html`, `PositronicKit/llms.txt`, `PositronicKit/Scripts/validate-docs.sh` | Establish and validate documentation authority. |
| `PositronicKit/Sources/PositronicKit/Services/Chat/Stages/ToolCallExtractionStage.swift` | Delete raw-text fallback invocation and fallback warning path. |
| `PositronicKit/Sources/PositronicKit/Utilities/ToolOutputParser.swift` | Delete raw-text parser. |
| `PositronicKit/Tests/PositronicKitTests/ToolOutputParserTests.swift` | Delete raw-text parser tests. |
| `PositronicKit/Tests/PositronicKitTests/ToolCallRegressionTests.swift` | Replace fallback assertion with a regression that raw text does not create tool calls. |

## Task 1: Make verification lanes manifest-driven

**Files:**
- Create: `PositronicKit/Scripts/list-library-products.swift`
- Modify: `PositronicKit/Makefile`
- Test: `PositronicKit/Scripts/list-library-products.swift` through Makefile targets

**Consumes:** `swift package describe --type json`.
**Produces:** `verify-products`, `verify-examples`, `verify-tests`, and a composed `verify` gate.

- [ ] **Step 1: Add a failing manifest-query check**

Run from `PositronicKit/`:

```bash
swift package describe --type json | swift Scripts/list-library-products.swift
```

Expected: FAIL because the script does not yet exist.

- [ ] **Step 2: Implement the portable product query**

Create a Foundation-based Swift script that decodes only the needed `products` shape and prints one product name per line when `type == "library"`:

```swift
import Foundation

struct Description: Decodable { let products: [Product] }
struct Product: Decodable { let name: String; let type: ProductType }
struct ProductType: Decodable { let name: String }

let data = FileHandle.standardInput.readDataToEndOfFile()
let description = try JSONDecoder().decode(Description.self, from: data)
for product in description.products where product.type.name == "library" {
    print(product.name)
}
```

Confirm the actual SwiftPM JSON shape with `swift package describe --type json`; adapt `ProductType` exactly to that schema rather than string-searching JSON.

- [ ] **Step 3: Verify the query result**

Run:

```bash
swift package describe --type json | swift Scripts/list-library-products.swift
```

Expected: every library in `Package.swift` appears once; `PositronicKitExamples` does not appear.

- [ ] **Step 4: Replace the manual Makefile list**

Replace `PRODUCTS := ...` with manifest-derived library products and retain one generated target per library:

```make
LIBRARY_PRODUCTS := $(shell swift package describe --type json | swift Scripts/list-library-products.swift)
PRODUCT_VERIFY_TARGETS := $(addprefix verify-product-,$(LIBRARY_PRODUCTS))

verify-examples:
	@echo "Building PositronicKitExamples..."
	@swift build --product PositronicKitExamples

verify-tests:
	@swift test

verify-products: $(PRODUCT_VERIFY_TARGETS)
verify: verify-pin validate-docs audit-default-linkage verify-products verify-examples verify-tests
```

Update `.PHONY`, `help`, and `verify-macos-default` so `verify` has one unambiguous composed contract and no duplicate test invocation.

- [ ] **Step 5: Verify each lane**

Run:

```bash
make verify-products
make verify-examples
make verify-tests
```

Expected: each lane succeeds; `verify-products` output includes every library and excludes the example executable.

- [ ] **Step 6: Commit**

```bash
git add Makefile Scripts/list-library-products.swift
git commit -m "build: derive product verification from manifest"
```

## Task 2: Make PKTestSupport test-only

**Files:**
- Modify: `PositronicKit/Package.swift`
- Test: `PositronicKit/Tests/PKTestSupportTests/**`

**Consumes:** existing `PKTestSupport` target under `Tests/PKTestSupport`.
**Produces:** a target usable by package test targets but absent from public products.

- [ ] **Step 1: Add a failing package-product assertion**

Run:

```bash
swift package describe --type json | swift Scripts/list-library-products.swift | rg '^PKTestSupport$'
```

Expected: currently finds `PKTestSupport` as a library product. Do not search the raw
package-description JSON: the retained target has the same name and would make that check pass
after its product is removed.

- [ ] **Step 2: Remove only the product declaration**

Delete this product line from `Package.swift` while preserving the target and `PKTestSupportTests` target:

```swift
.library(name: "PKTestSupport", targets: ["PKTestSupport"]),
```

Do not move `Tests/PKTestSupport` and do not change helper behavior.

- [ ] **Step 3: Verify package-internal consumers**

Run:

```bash
swift test --filter PKTestSupportTests
swift test
swift package describe --type json
```

Expected: tests using `PKTestSupport` compile; the product list no longer exposes it.

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "build: keep test support internal"
```

## Task 3: Align test targets with owned modules

**Files:**
- Modify: `PositronicKit/Package.swift`
- Move: provider-specific files from `Tests/PositronicKitTests/` to `Tests/PKOpenAIProviderTests/`, `Tests/PKOpenRouterProviderTests/`, `Tests/PKOllamaProviderTests/`, `Tests/PKAnthropicProviderTests/`, and `Tests/PKFoundationModelsProviderTests/`
- Move: PKShared model/utility tests to `Tests/PKSharedTests/`
- Test: each new test target

**Consumes:** provider products, `PKShared`, and internal `PKTestSupport`.
**Produces:** one test target per provider and a core target without concrete provider ownership.

- [ ] **Step 1: Classify every candidate by imports and production owner**

Create the move table before editing. At minimum classify:

```text
PKOpenAIProviderTests: OpenAIMessageConversionLoggingTests, OpenAIReasoningDeltaTests,
  OpenAIToolCallRecoveryTests, OpenAITransportContractTests, OpenAIToolConversionTests
PKOpenRouterProviderTests: OpenRouterMessageConversionLoggingTests, OpenRouterToolCallRecoveryTests
PKOllamaProviderTests: Services/LLM/Providers/Ollama/OllamaClientTests
PKAnthropicProviderTests: AnthropicStreamDecodingTests
PKFoundationModelsProviderTests: FoundationModelsAvailabilityTests, FoundationModelsClientTests,
  FoundationModelsStreamMapperTests, FoundationModelsToolBridgeTests, FoundationNetworkingImportAuditTests
PKSharedTests: AnyCodableTests, GenerationParametersTests, AgentTemplateModelTests,
  APIResponseMetadataTests, MemoryModelTests, WorkspaceURITests, WorkspaceToolDefinitionTests,
  WorkspaceReferenceTests, LLMConfigurationModelsTests
```

Keep `ProviderTransportContractTests`, `ProviderHTTPFailureTests`, `ProviderInitializationTests`, and `StreamDecodingConformanceTests` in core unless their dependencies prove they test a single adapter.

- [ ] **Step 2: Add failing target-resolution checks**

Add each test target in `Package.swift`, then run before moving sources:

```bash
swift test list | rg 'PKOpenAIProviderTests|PKSharedTests'
```

Expected: no matching test names until moves are complete. `swift test --filter` is a
test-name filter, not a test-target selector, so do not use it as a target-resolution check.

- [ ] **Step 3: Add module-owned target dependencies and move tests**

For each new target, depend on exactly its provider target, `PKShared`, and `PKTestSupport` only when imported. Add direct package products such as `OpenAI`, `Logging`, or `JSONSchemaBuilder` only where the moved source imports them. Move files without rewriting behavior; update imports to the provider module where required.

For `PKSharedTests`, move PKShared-owned files into matching `SharedTypes/` or `Utilities/` folders and add `PKTestSupport` only for tests that use it.

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
swift test list | rg 'PKOpenAIProviderTests'
swift test --filter 'PKOpenAIProviderTests\.'
swift test list | rg 'PKOpenRouterProviderTests'
swift test --filter 'PKOpenRouterProviderTests\.'
swift test list | rg 'PKOllamaProviderTests'
swift test --filter 'PKOllamaProviderTests\.'
swift test list | rg 'PKAnthropicProviderTests'
swift test --filter 'PKAnthropicProviderTests\.'
swift test list | rg 'PKFoundationModelsProviderTests'
swift test --filter 'PKFoundationModelsProviderTests\.'
swift test list | rg 'PKSharedTests'
swift test --filter 'PKSharedTests\.'
swift test
```

Expected: every `swift test list` command finds at least one test, each corresponding filter
executes it, and the full suite passes.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests
git commit -m "test: align coverage with package targets"
```

## Task 4: Establish documentation and layout authority

**Files:**
- Modify or delete: `PositronicKit/Sources/PositronicKit/README.md`
- Modify: `PositronicKit/Scripts/validate-docs.sh`
- Modify if generated: generation source/command for `PositronicKit/docs/index.html` and `PositronicKit/llms.txt`
- Test: `make validate-docs`

**Consumes:** root docs, DocC bundle, story tests, rendered index, and LLM guide.
**Produces:** a single maintained source plus a drift-detecting validation path for each documentation artifact.

- [ ] **Step 1: Determine each artifact's authority**

For `docs/index.html` and `llms.txt`, inspect Git history and current scripts to identify an existing generator. Record one of these exact contracts in the contributor docs:

```text
Generated: <command> rewrites the artifact; validation regenerates to a temporary file and diffs it.
Authored: <named source file> is hand-maintained; validation checks links and public symbols.
```

If no trustworthy generator exists, choose `Authored` rather than inventing an unreviewed site-generation system in this tranche.

- [ ] **Step 2: Remove duplicate target README guidance**

Delete `Sources/PositronicKit/README.md` if it repeats root docs, or replace its body with a short pointer:

```markdown
# PositronicKit runtime target

Maintained documentation lives in the package root README and `Sources/PositronicKit/PositronicKit.docc`.
```

The target README must not contain runnable initialization code that can drift from the facade documentation.

- [ ] **Step 3: Encode the authority in validation**

Extend `Scripts/validate-docs.sh` with the selected artifact checks. Preserve the existing story-suite and DocC checks. A generated artifact mismatch must exit non-zero with a command that tells the maintainer how to regenerate it; authored artifacts must be included in the relevant link/symbol validation command.

- [ ] **Step 4: Verify documentation**

Run:

```bash
make validate-docs
```

Expected: story tests and DocC validation run; each tracked documentation artifact is validated by its selected contract.

- [ ] **Step 5: Commit**

```bash
git add Sources/PositronicKit/README.md Scripts/validate-docs.sh docs/index.html llms.txt README.md docs
git commit -m "docs: define documentation authority"
```

## Task 5: Remove raw-text tool-call inference

**Files:**
- Modify: `Monad/**`, `Shuttle/**`, `Yakamoz/**` only if the audit finds and removes a dependency
- Delete: `PositronicKit/Sources/PositronicKit/Utilities/ToolOutputParser.swift`
- Modify: `PositronicKit/Sources/PositronicKit/Services/Chat/Stages/ToolCallExtractionStage.swift`
- Delete: `PositronicKit/Tests/PositronicKitTests/ToolOutputParserTests.swift`
- Modify: `PositronicKit/Tests/PositronicKitTests/ToolCallRegressionTests.swift`, `PositronicKit/CHANGELOG.md`

**Consumes:** provider-native `toolCallAccumulators`, `ToolCallExtractionStage`, and consumer tool configuration.
**Produces:** only provider-native structured calls can enter the execution path.

- [ ] **Step 1: Audit all three consumers before any deletion**

Run from workspace root:

```bash
rg -n "ToolOutputParser|tool_call_begin|<tool_call>|raw-text tool|fallback.*tool" Monad Shuttle Yakamoz --glob '*.swift' --glob '*.md'
```

Expected: record every match in the ticket. If a consumer depends on a non-native model tool format, stop this task and revise its migration before deletion.

- [ ] **Step 2: Add a failing non-execution regression**

In `ToolCallRegressionTests`, build a turn with non-empty available tools and assistant content containing each legacy form. Assert no `ChatEvent.toolCall` is emitted and no tool accumulator is created:

```swift
#expect(events.filter { if case .toolCall = $0 { true } else { false } }.isEmpty)
#expect(await context.outputs.toolCallAccumulators.isEmpty)
```

Run:

```bash
swift test --filter ToolCallRegressionTests
```

Expected: FAIL while the fallback path synthesizes calls.

- [ ] **Step 3: Delete the fallback behavior**

Delete the `ToolOutputParser.parse` block from `ToolCallExtractionStage.process`, including fallback warning metadata and synthetic accumulator/event creation. Retain accumulator diagnostics, sentinel/empty cleanup, debug recording, and all structured-call handling.

Delete `ToolOutputParser.swift` and its dedicated tests. Remove only raw-text recovery assertions from `ToolCallRegressionTests`; keep structured tool-call regression coverage.

- [ ] **Step 4: Verify native calls and fallback non-execution**

Run:

```bash
swift test --filter ToolCallRegressionTests
swift test --filter ToolOutputParserTests
swift test --filter ProviderTransportContractTests
swift test
```

Expected: the parser filter reports no selected tests because its suite was deleted; regression tests prove raw text is not executable; provider contract tests and full suite pass.

- [ ] **Step 5: Document the behavior change**

Add an `Unreleased` CHANGELOG entry stating that PositronicKit no longer infers executable calls from assistant text. State that models must supply provider-native structured tool calls and that XML/pipe/fenced JSON remains ordinary content.

- [ ] **Step 6: Run the release-hygiene gate and commit**

Run:

```bash
make verify
```

Expected: products, examples, docs, linkage, and tests pass.

Commit:

```bash
git add Sources Tests CHANGELOG.md
git commit -m "security: remove raw text tool call fallback"
```

## Plan self-review

- Spec coverage: Tasks 1–4 implement manifest verification, test ownership, test support privacy, and documentation authority; Task 5 implements the separately approved raw-text removal with the required consumer audit.
- Type consistency: every Makefile lane and SwiftPM target name is defined in the task that creates it.
- Scope: TimelineManager, workspace seams, provider capabilities, and normal structured tool execution remain untouched.
