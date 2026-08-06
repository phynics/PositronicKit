# PKR-14 — MiniLM backend maintenance: duplicated source file + string-parsed error round-trip

**Status:** Done
**Severity:** 🟡 Low (drift-prone dual maintenance)
**Repos:** PositronicKit (MiniLM backends, PKShared)
**Source:** PositronicKit review 2026-07-02

## Problem

1. **Byte-identical duplicate:** `Sources/PKMiniLMLinuxBackend/PKMiniLMPlatformBackend.swift` and
   `Sources/PKMiniLMTraitBackend/PKMiniLMPlatformBackend.swift` are identical apart from the
   `#if MiniLMEmbeddings` wrapper (diff-verified). The two targets never compile together
   (Linux vs macOS trait), so a fix applied to one and not the other is never caught.
2. **Fragile error round-trip:** both copies (`:43-45`) reconstruct a typed
   `EmbeddingInputBudget.ValidationError` by **parsing the formatted message string** produced by
   `MiniLMEmbedder.validate` (`PKFastEmbed.swift:175-189`). A wording change in
   `EmbeddingInputBudget.ValidationError.message` (PKShared) silently degrades budget errors to
   generic `.generationFailed` with no compiler signal.

## Suggested direction

Factor the shared actor into one target both backends depend on (or into PKFastEmbed itself).
Carry the typed validation error across the boundary as an associated value instead of a
formatted string; at minimum pin the exact message text with a unit test so wording changes
break CI.

## Resolution (2026-07-04)

Moved the shared `PKMiniLMPlatformBackend` actor into `PKFastEmbed` (the common dependency both
the Linux platform-condition and `MiniLMEmbeddings` trait-condition already resolve to), and
deleted the now-empty `PKMiniLMLinuxBackend`/`PKMiniLMTraitBackend` targets. `PKFastEmbed` gained a
`PositronicKit` dependency for `EmbeddingError` (no cycle). Grepped Monad/Shuttle/Yakamoz for the
removed target/type names — zero references, fully internal to PositronicKit.

Added `PKFastEmbedError.budgetExceeded(EmbeddingInputBudget.ValidationError)`, carrying the typed
validation error across the `PKFastEmbed`/backend boundary as an associated value instead of a
formatted string that got re-parsed. `mapError`'s switch is now exhaustive over this case.

Updated the four budget-limit tests in `PKFastEmbedTests.swift` to assert on the typed case and its
`max`/`actual` values instead of message-substring matching. Full suite green.
