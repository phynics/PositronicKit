---
status: accepted
---

# v4 hard domain and persistence cut

PositronicKit v4 adopts a hard domain and persistence cut: the target runtime exposes Thread, Turn,
Agent, and Workspace as its canonical model and must not read v3 Timeline-era data or retain
runtime compatibility aliases, decoders, migrators, or fallback tool names. We reject a
compatibility layer because it would preserve two authorities and two vocabularies; custom stores
own migration or discard, while built-in in-memory stores start empty and incompatible generations
fail clearly.
