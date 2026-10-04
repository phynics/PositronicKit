---
status: accepted
---

# Embeddings return as a runtime-neutral capability

## Context

Commit `534efdea` removed the embedding subsystem during the domain convergence: the
`EmbeddingServiceProtocol`, the `PKLocalEmbeddings` and `PKFastEmbed` products, the MiniLM model
pin, and the `VectorStoreProtocol` seam all left the package. ADR 0006 recorded the removal as a
boundary: semantic retrieval stays outside the package until a separately owned contract has a
concrete consumer, and it rejected reviving the automatic memory pipeline.

[Issue #242](https://github.com/phynics/PositronicKit/issues/242) asks for a redesigned embedding
capability, not a restoration. The old subsystem failed on three counts, and a return must fix all
three:

1. It coupled a provider-specific backend (`PKFastEmbed` / MiniLM) to the contracts, so a Linux
   build depended on an Apple model bridge.
2. It exposed a retrieval service and a vector store that implied the runtime owned semantic
   search. The runtime never called either, and ADR 0006 exists to keep that boundary.
3. Its embeddings carried no identity, so a vector from one model could be compared silently
   against a vector from another.

The consumer story is a host that owns its notes and wants to inject the most relevant ones into
a Turn. That host needs three things and nothing more: a text-to-vector contract, a way to tell
whether two vectors are comparable, and a bounded request shape. The runtime must gain no
embedding API of its own, because a Turn's context is already assembled from host-supplied
`AgentContextSource` and `TurnContextSource` values.

## Decision

**Embedding is a capability value in `PKContracts`, not a runtime feature.** `PKContracts` owns
`EmbeddingClientProtocol`, `EmbeddingRequest`, `EmbeddingResponse`, `Embedding`, `EmbeddingSpace`,
`EmbeddingPurpose`, `EmbeddingInputBudget`, and `EmbeddingError`. The protocol is separate from
`LLMClientProtocol` so a text-only provider is never forced to stub an embedding method.
`PKContracts` imports no project target, so any provider product can conform without the runtime.

**A vector carries its space.** `Embedding` pairs the vector with an `EmbeddingSpace` value
holding provider, model, dimensions, and normalization. `Embedding.cosineSimilarity(to:)` throws
`EmbeddingError.incompatibleSpaces` when the two spaces differ. This is the concrete fix for the
old anonymous-vector defect and is covered by a test that compares vectors from two providers.

**The runtime does not retrieve.** PositronicKit gains no embedding client, no vector store, and
no automatic retrieval stage. A host calls its own `EmbeddingClientProtocol`, ranks its own data,
and contributes the result through the existing context seams. This keeps ADR 0006's boundary
intact while making the missing contract available. Provider products expose factories
(`PKOpenAI.makeEmbeddingClient`, `PKOllama.makeEmbeddingClient`) but the runtime never
instantiates or calls them.

**Clients declare a budget and validate before I/O.** `EmbeddingInputBudget` bounds text count,
bytes per text, and total bytes. `EmbeddingClientProtocol.embedDocuments(_:)` splits a large set
into admitted batches, and `embedQuery(_:)` is the single-text convenience. Every client validates
before it touches the network or a local model.

**Three providers ship, plus a deterministic test double.** `OpenAIEmbeddingClient` calls
`POST /v1/embeddings`; `OllamaEmbeddingClient` calls `POST /api/embed`; and
`AppleNaturalLanguageEmbeddingClient` wraps `NLEmbedding.sentenceEmbedding(for:)`. The Apple
client lives in `PKFoundationModelsProvider` behind a file-level `#if canImport(NaturalLanguage)`
guard rather than a new product: it is an on-device adapter with no HTTP transport, and a separate
package for one platform-gated type would add a product without adding a boundary.
`MockEmbeddingClient` in `PKTestSupport` and `EmbeddingClientConformanceSuite` let each provider
test prove order preservation, budget rejection before I/O, response-count checking, and batch
boundaries.

**The example is the documented integration path.** `EmbeddingRetrievalContextSource` in
`PositronicKitExamples` embeds the admitted Turn input, ranks a host-owned list of pre-computed
notes with `cosineSimilarity(to:)`, and returns the top results as bounded
`TurnContextContribution` values. It is a host implementation, not a runtime stage.

## Consequences

A host can now add semantic context without a provider-specific product and without the runtime
growing a retrieval path. Provider clients are independently usable and testable. Comparing
embeddings from different models fails loudly instead of producing a meaningless score.

The package still ships no vector index, no persistence for embeddings, and no automatic
injection. A host that needs those builds them and feeds `AgentContextSource` or
`TurnContextSource`. That is the intended cost: the contract is narrow, and the search policy
stays with the data owner.

`PKErrorDomain.embedding` returns with codes `8001`, `8002`, and `8007`–`8009` matching the former
subsystem. Codes `8003`–`8006` stay unused; they belonged to the removed MiniLM backend.
`incompatibleSpaces` and `responseCountMismatch` take `8010` and `8011`.

This ADR amends decision 1 of [ADR 0006](0006-memory-retrieval-and-prompt-boundaries.md). The
boundary that decision protected — no automatic global memory pipeline — still stands. What
changes is that the separately owned contract now exists, with a concrete consumer and a
persistence story that remains entirely host-owned.

## Rejected alternatives

- **Restore `EmbeddingServiceProtocol` and the local products.** It would revive the MiniLM pin
  and the Apple-only backend that the removal intentionally dropped.
- **Put the clients in `PositronicKit`.** The runtime must not import provider transports or
  platform models, and ADR 0002 keeps contracts and implementations apart.
- **Add a fourth product for the Apple client.** A new product is a support commitment. A guarded
  file in the existing Foundation Models product adds the platform adapter without widening the
  product graph.
- **Drop `EmbeddingSpace` and let callers track the model.** The old subsystem did exactly that
  and allowed silent cross-model comparisons. Carrying the space makes the failure explicit.
- **Fold embedding into `LLMClientProtocol`.** A text-only provider would have to stub the method,
  which is the kind of optional-capability lie the type system should prevent.
