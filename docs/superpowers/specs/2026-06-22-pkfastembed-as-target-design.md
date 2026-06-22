# Fold PKFastEmbed into PositronicKit as targets

**Date:** 2026-06-22
**Status:** Design (pending implementation plan)

## Goal

Move `PKFastEmbed` from a nested SwiftPM package (`Packages/PKFastEmbed`, consumed via
`.package(path:)`) into the root `PositronicKit` package as ordinary targets. After this change
PositronicKit owns `CPKFastEmbed`, `PKFastEmbed`, and `PKFastEmbedTests` directly; the nested
package directory is deleted.

Non-goal: changing the native Rust bridge, its ABI, the embedding behavior, the model pin, or the
public surface of any other target. This is a structural relocation only.

## Background / Why it is currently a separate package

`PKFastEmbed` wraps a native Rust static library (`libpkfastembed.a`) through a `.systemLibrary`
target `CPKFastEmbed` (`pkgConfig: "pkfastembed"`). The native lib must be built and a
`pkfastembed.pc` produced by `bootstrap.sh` before the system library can link.

The decisive reason it lives in its own package today is its **test target**: `PKFastEmbedTests`
links the native lib. Keeping it in a separate package keeps that native-linking test out of the
default root `swift test`; the suite only ever ran via `swift test --package-path Packages/PKFastEmbed`.

A prior incident (`make verify-minilm` exiting 0 while running **0 tests**) was caused by guarding
that suite with `#if os(Linux) || MiniLMEmbeddings` while the `MiniLMEmbeddings` trait was declared
only in the *PositronicKit root* manifest — the standalone package had no such trait, so on macOS
the guard was always false. That pitfall is the reason the test-gating decision below matters, and
why moving the trait and the test into the **same** manifest makes the `#if` guard safe.

## Current structure (before)

Root `Package.swift` (relevant excerpts):

```swift
dependencies: [
    // ...
    .package(path: "Packages/PKFastEmbed"),
],
targets: [
    // ...
    .target(
        name: "PKMiniLMLinuxBackend",
        dependencies: [
            "PositronicKit",
            .product(name: "PKFastEmbed", package: "PKFastEmbed"),
        ],
        path: "Sources/PKMiniLMLinuxBackend"
    ),
    .target(
        name: "PKMiniLMTraitBackend",
        dependencies: [
            "PositronicKit",
            .product(
                name: "PKFastEmbed",
                package: "PKFastEmbed",
                condition: .when(traits: ["MiniLMEmbeddings"])
            ),
        ],
        path: "Sources/PKMiniLMTraitBackend"
    ),
]
```

Nested package `Packages/PKFastEmbed/Package.swift`:

```swift
targets: [
    .systemLibrary(name: "CPKFastEmbed", pkgConfig: "pkfastembed"),
    .target(name: "PKFastEmbed", dependencies: ["CPKFastEmbed"]),
    .testTarget(name: "PKFastEmbedTests", dependencies: ["PKFastEmbed"]),
]
```

Nested package file tree (excluding `native/target/` build artifacts):

```
Packages/PKFastEmbed/
  Package.swift
  README.md
  THIRD_PARTY_NOTICES.md
  bootstrap.sh
  model-assets.sha256
  native/
    Cargo.toml
    Cargo.lock
    include/pkfastembed.h
    src/lib.rs
  Sources/CPKFastEmbed/
    module.modulemap
    include/pkfastembed.h
  Sources/PKFastEmbed/PKFastEmbed.swift
  Tests/PKFastEmbedTests/PKFastEmbedTests.swift
```

`PKFastEmbed` consumers in source:

- `Sources/PKMiniLMLinuxBackend/PKMiniLMPlatformBackend.swift`: `import PKFastEmbed`
- `Sources/PKMiniLMTraitBackend/PKMiniLMPlatformBackend.swift`: `import PKFastEmbed`

These imports are unchanged by the move (same module name).

## Target structure (after)

### Root `Package.swift`

1. **Remove** the path dependency:

```swift
- .package(path: "Packages/PKFastEmbed"),
```

2. **Add** three targets:

```swift
.systemLibrary(
    name: "CPKFastEmbed",
    path: "Sources/CPKFastEmbed",
    pkgConfig: "pkfastembed"
),
.target(
    name: "PKFastEmbed",
    dependencies: ["CPKFastEmbed"],
    path: "Sources/PKFastEmbed"
),
.testTarget(
    name: "PKFastEmbedTests",
    dependencies: [
        .target(name: "PKFastEmbed", condition: .when(traits: ["MiniLMEmbeddings"])),
    ],
    path: "Tests/PKFastEmbedTests"
),
```

3. **Rewrite** the two backend dependencies from product refs to local target refs, preserving the
existing platform/trait gating semantics:

```swift
// PKMiniLMLinuxBackend
- .product(name: "PKFastEmbed", package: "PKFastEmbed"),
+ "PKFastEmbed",

// PKMiniLMTraitBackend
- .product(
-     name: "PKFastEmbed",
-     package: "PKFastEmbed",
-     condition: .when(traits: ["MiniLMEmbeddings"])
- ),
+ .target(name: "PKFastEmbed", condition: .when(traits: ["MiniLMEmbeddings"])),
```

`PKMiniLMLinuxBackend`'s dep stays unconditional because the target itself is only pulled into
`PKLocalEmbeddings` under `.when(platforms: [.linux])`, so it does not build on the default macOS
host. No new `.library` product is exported for `PKFastEmbed`; it remains an internal target.

### File moves

| From | To |
|------|----|
| `Packages/PKFastEmbed/Sources/CPKFastEmbed/` | `Sources/CPKFastEmbed/` |
| `Packages/PKFastEmbed/Sources/PKFastEmbed/` | `Sources/PKFastEmbed/` |
| `Packages/PKFastEmbed/Tests/PKFastEmbedTests/` | `Tests/PKFastEmbedTests/` |
| `Packages/PKFastEmbed/native/` + `bootstrap.sh` + `model-assets.sha256` + `THIRD_PARTY_NOTICES.md` + `README.md` | `native/pkfastembed/` (flattened: crate files at top level alongside bootstrap.sh/assets) |

Use `git mv` so history is preserved. `native/target/` build artifacts are not moved (regenerated by
bootstrap). The `.swiftpm/` Xcode user data in the nested package is discarded.

`native/pkfastembed/` is a non-target directory at the package root; SwiftPM does not treat it as a
target, so its presence does not affect the build graph.

### Test gating (the only behavioral change)

Wrap the **entire body** of `Tests/PKFastEmbedTests/PKFastEmbedTests.swift` in:

```swift
#if MiniLMEmbeddings
import CPKFastEmbed
// ... all existing imports, the @Suite, and the NativeAPIHarness ...
#endif
```

Behavior matrix:

| Invocation | `MiniLMEmbeddings` trait | PKFastEmbed dep present | Tests compiled | Tests run |
|------------|--------------------------|--------------------------|----------------|-----------|
| `swift test` (default `make test`) | off | no (gated dep) | none (empty file) | 0 (intended) |
| Linux CI default | off | no | none | 0 (intended) |
| `swift test --traits MiniLMEmbeddings` (host `verify-minilm`) | on | yes | yes | all |

This is safe (unlike the prior incident) because `MiniLMEmbeddings` is declared in this manifest, so
`#if MiniLMEmbeddings` reflects reality whenever `--traits MiniLMEmbeddings` is passed.

**Accepted trade-off:** previously the suite could run on Linux via the standalone-package path;
under trait-gating it runs only when the trait is enabled (the macOS `verify-minilm` host path).
Acceptable because the suite needs the bootstrapped native lib regardless.

### Script and Makefile updates

**`native/pkfastembed/bootstrap.sh`** — the script currently treats its own directory as the package
root and looks under `$SCRIPT_DIR/native/…`. After flattening, the crate *is* `$SCRIPT_DIR`:

```sh
- RUST_TARGET_DIR="${SCRIPT_DIR}/native/target"
+ RUST_TARGET_DIR="${SCRIPT_DIR}/target"

- pushd "${SCRIPT_DIR}/native" >/dev/null
+ pushd "${SCRIPT_DIR}" >/dev/null

- cp "${SCRIPT_DIR}/native/target/release/libpkfastembed.a" "${PREFIX}/lib/"
- cp "${SCRIPT_DIR}/native/include/pkfastembed.h" "${PREFIX}/include/"
+ cp "${SCRIPT_DIR}/target/release/libpkfastembed.a" "${PREFIX}/lib/"
+ cp "${SCRIPT_DIR}/include/pkfastembed.h" "${PREFIX}/include/"
```

**`Scripts/bootstrap-minilm-ci.sh`**:

```sh
- manifest="Packages/PKFastEmbed/model-assets.sha256"
+ manifest="native/pkfastembed/model-assets.sha256"

- Packages/PKFastEmbed/bootstrap.sh --prefix "$prefix"
+ native/pkfastembed/bootstrap.sh --prefix "$prefix"
```

**`Makefile`** `verify-minilm` target — replace the standalone-package test run with a trait-filtered
run in the unified package:

```makefile
- @PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
-     swift test --package-path Packages/PKFastEmbed
+ @PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
+     swift test --traits MiniLMEmbeddings --filter PKFastEmbedTests
```

The `audit-default-linkage` grep (`libpkfastembed|-lpkfastembed|PKFastEmbed\.build|PKMiniLMTraitBackend\.build`)
remains valid and unchanged.

### Cleanup

Delete the now-empty `Packages/PKFastEmbed/` directory (and `Packages/` if it becomes empty).

## Risks and mitigations

- **Default `swift build`/`swift test` accidentally probing pkg-config.** A `.systemLibrary` target
  is only built when something depends on it in the active configuration. Under default traits on
  macOS, nothing depends on `CPKFastEmbed`, so pkg-config is not invoked. Verified by step 1 and 2
  below.
- **Zero-tests false positive.** Explicitly assert a non-zero executed count in `verify-minilm`
  (step 3), per the standing verification rule.
- **Stale references to `Packages/PKFastEmbed`.** Grep the repo after the move; the known references
  are the three scripts/Makefile edits above plus docs.

## Verification

1. `swift build` (default) — succeeds; no pkg-config invocation.
2. `make audit-default-linkage` — confirms native lib absent from default `PKLocalEmbeddings` build.
3. `make verify-minilm` — bootstraps the lib, runs the MiniLM contract tests **and**
   `PKFastEmbedTests`; confirm the executed test count is **non-zero** (not just exit 0).
4. `grep -rn "Packages/PKFastEmbed"` returns nothing outside historical docs.
5. `make verify` / `make verify-products` still pass.

## Out of scope

- Changing the Rust crate, ABI, or model pin.
- Exporting `PKFastEmbed` as a public product.
- Touching `Monad` or `Shuttle` (neither references `PKFastEmbed` directly).
