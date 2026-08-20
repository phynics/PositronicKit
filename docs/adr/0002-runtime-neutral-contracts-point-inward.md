---
status: accepted
---

# Runtime-neutral contracts point inward

The v4 design assigns PKContracts as the leaf product for provider-neutral messages, model clients,
tools, structured output, embeddings, and diagnostics; PKPrompt, providers, and embedding
implementations must consume it, and the PositronicKit runtime must compose those lower-level
contracts. We reject retaining a shared grab-bag that imports runtime targets because downstream
providers and embeddings must compile without the runtime, and the boundary must remain
independently consumable.
