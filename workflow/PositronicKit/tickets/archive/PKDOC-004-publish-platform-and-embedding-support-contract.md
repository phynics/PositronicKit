# PKDOC-004: Publish the Final Platform and Embedding Support Contract

**Priority:** P2  
**Type:** Documentation  
**Depends on:** PKEMBED-002, PKCI-003  
**Blocks:** None  
**Status:** Closed

### Summary

Update public documentation after real Linux and trait-enabled macOS verification exists. Remove provisional labels and document model provisioning, trait usage, and the requirement to rebuild embeddings when moving persisted content between Apple and Linux.

### Required Documentation

- Product support matrix backed by passing verification rather than "portable candidate" labels.
- `PKLocalEmbeddings` installation and imports.
- Apple default Natural Language example.
- Linux `LocalEmbeddingService(modelDirectory:)` example.
- Apple `MiniLMEmbeddings` trait declaration and `LocalEmbeddingService(miniLMModelDirectory:)` example.
- Exact model asset filenames, revision, checksums, and host-owned cache responsibility.
- Clear statement that Apple Natural Language and MiniLM vectors cannot share a similarity index.
- Migration instruction: copy source content, then rebuild embeddings on the destination platform.
- Explicit statement that no provider or daemon fallback is used.

### Acceptance Criteria

- [x] Every README command is exercised in verification or a compiled documentation test.
- [x] Support labels match the required verification targets from PKCI-003.
- [x] No documentation describes `swift-foundation` as an application package dependency.
- [x] No documentation promises multi-model selection or cross-platform-compatible vectors.
- [x] The public source migration from `PositronicKit.LocalEmbeddingService` to `PKLocalEmbeddings.LocalEmbeddingService` is called out.

### Progress Note (2026-07-04)

`README.md`, `llms.txt`, and `native/pkfastembed/README.md` now remove the
provisional local-embedding support language and document the three supported
construction paths explicitly: Apple default (`LocalEmbeddingService()`),
Linux (`LocalEmbeddingService(modelDirectory:)`), and Apple MiniLM behind the
`MiniLMEmbeddings` trait (`LocalEmbeddingService(miniLMModelDirectory:)`).
The docs now call out the public migration from
`PositronicKit.LocalEmbeddingService` to `PKLocalEmbeddings.LocalEmbeddingService`,
list the exact pinned asset filenames plus revision/checksum source of truth,
state that there is no provider or daemon fallback, and instruct consumers to
copy source content then rebuild embeddings when moving across backends or
platforms.

Documentation validation passed locally via `make validate-docs`, and the
support-contract commands now have real macOS evidence from
`make verify-macos-default` and `make verify-macos-minilm` on July 4, 2026.
With `PKCI-003` later satisfied by the user's Linux host-matrix execution,
the verification contract is fully backed by real host evidence. This ticket
is closed.
