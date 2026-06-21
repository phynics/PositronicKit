# Manual Verification Makefile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace GitHub-hosted CI with manually invoked Make targets while keeping MiniLM verification opt-in.

**Architecture:** The root `Makefile` is the single verification interface. Default verification composes documentation, linkage, build, and test targets; MiniLM verification composes the existing bootstrap script, trait tests, and companion tests using repository-local `.build` paths.

**Tech Stack:** Make, Bash, Swift Package Manager, Cargo, pkg-config

## Global Constraints

- Delete `.github/workflows/ci.yml` rather than leaving disabled jobs.
- Preserve `build`, `clean`, `test`, `test-parallel`, and `harden`.
- Keep MiniLM download and native compilation out of `make verify`.
- Use overridable `PKFASTEMBED_PREFIX` and `PK_MINILM_MODEL_DIR` variables.
- Stop verification on the first failing command.

---

### Task 1: Replace Hosted CI with Make Targets

**Files:**
- Modify: `Makefile`
- Delete: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `Scripts/validate-docs.sh`, `Scripts/bootstrap-minilm-ci.sh`, SwiftPM products and traits
- Produces: `verify`, `verify-products`, `verify-minilm`, `audit-default-linkage`, `bootstrap-minilm`

- [ ] **Step 1: Run the failing interface check**

Run: `make -n verify verify-products verify-minilm`

Expected: FAIL because the requested targets do not exist.

- [ ] **Step 2: Add variables and targets**

Add these variables:

```make
PKFASTEMBED_PREFIX ?= $(CURDIR)/.build/pkfastembed
PK_MINILM_MODEL_DIR ?= $(CURDIR)/.build/minilm-model
export PKFASTEMBED_PREFIX
export PK_MINILM_MODEL_DIR

PRODUCTS := PKShared PKPrompt PositronicKit PKLocalEmbeddings \
	PKOpenRouterProvider PKOllamaProvider PKOpenAIProvider PositronicKitExamples
```

Add these targets to `.PHONY` and implement them:

```make
validate-docs:
	@bash Scripts/validate-docs.sh

audit-default-linkage:
	@swift build --target PKLocalEmbeddings --verbose > .build/default-build.log 2>&1
	@! grep -E "libpkfastembed|-lpkfastembed|PKFastEmbed\\.build|PKMiniLMTraitBackend\\.build" .build/default-build.log

verify-products:
	@set -e; for product in $(PRODUCTS); do \
		echo "Building $$product..."; \
		swift build --product "$$product"; \
	done

verify: validate-docs audit-default-linkage test

bootstrap-minilm:
	@bash Scripts/bootstrap-minilm-ci.sh

verify-minilm: bootstrap-minilm
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" swift test --traits MiniLMEmbeddings --filter MiniLMEmbeddingContractTests
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" swift test --package-path Packages/PKFastEmbed
```

Update `help` with the three verification entry points and note that MiniLM downloads pinned assets.

- [ ] **Step 3: Remove hosted CI**

Delete `.github/workflows/ci.yml`; remove `.github/workflows` if empty.

- [ ] **Step 4: Verify parsing and removal**

Run:

```bash
make -n verify
make -n verify-products
make -n verify-minilm
test ! -e .github/workflows/ci.yml
```

Expected: exit 0. Default verification omits MiniLM bootstrap; MiniLM verification includes bootstrap and trait tests.

---

### Task 2: Document Manual Verification

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: Task 1 Make targets
- Produces: contributor instructions for default, product, and MiniLM checks

- [ ] **Step 1: Run the failing documentation check**

Run: `rg -n "make verify-minilm|make verify-products" README.md AGENTS.md`

Expected: FAIL because the commands are not documented.

- [ ] **Step 2: Document commands and overrides**

Add:

```text
make verify           # Default build, docs, linkage audit, and tests
make verify-products  # Build every supported product on the current host
make verify-minilm    # Bootstrap pinned assets/native bridge and run MiniLM tests
```

State that `verify-minilm` downloads pinned Hugging Face assets on first use, validates checksums, builds the Rust bridge, and stores both under `.build`. Document overrides:

```bash
make verify-minilm \
  PKFASTEMBED_PREFIX=/path/to/prefix \
  PK_MINILM_MODEL_DIR=/path/to/model
```

- [ ] **Step 3: Verify documentation**

Run: `rg -n "make verify-minilm|make verify-products" README.md AGENTS.md && bash Scripts/validate-docs.sh`

Expected: commands appear in both files and validation exits 0.

---

### Task 3: Run Manual Verification Gates

**Files:**
- Verify: `Makefile`, `README.md`, `AGENTS.md`

**Interfaces:**
- Consumes: Tasks 1-2
- Produces: fresh verification evidence

- [ ] **Step 1: Run default verification**

Run: `make verify`

Expected: documentation, linkage audit, and Swift tests pass.

- [ ] **Step 2: Run native unit checks without model download**

Run: `cargo test --locked --manifest-path Packages/PKFastEmbed/native/Cargo.toml`

Expected: all Rust native-boundary tests pass.

- [ ] **Step 3: Check the diff**

Run: `git diff --check && git status --short`

Expected: no whitespace errors; only planned files changed.

- [ ] **Step 4: Commit**

```bash
git add Makefile README.md AGENTS.md .github/workflows/ci.yml
git commit -m "build: replace hosted CI with manual verification"
```

