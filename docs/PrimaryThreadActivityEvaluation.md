# Primary-Thread activity projection evaluation

This document records the bounded evaluation for issue [#72](https://github.com/phynics/PositronicKit/issues/72).
The projector is an internal, best-effort experiment. It is not a public history contract, and its
messages are provenance-bearing evaluation data rather than a replacement for the source Thread.

## Evaluation matrix

| Case | Expected result | Evidence in this change |
| --- | --- | --- |
| Resolved primary Workspace succeeds | Assistant tool declaration and bounded tool result are appended to the Agent private Thread | `workspaceCallToolPrimaryActivityProjection` |
| Resolved primary Workspace fails, is denied, times out, or cannot persist | A bounded tool/error result is projected without changing the source Turn outcome | ToolRouter terminal/error projection paths; outcome encoding covers all cases |
| Ambiguous or unresolved Workspace call | No projection; correction remains on the source Turn | Workspace ambiguity routing and notice tests |
| Activity originating on the primary/private Thread | No projection | Sink source/target guard |
| Private Thread is active | Activity waits behind the active Turn and is committed under the shared Thread authority lane | `primaryActivityProjectionQueuesAndDeduplicates` |
| Duplicate delivery or restart retry | Deterministic message IDs and the required atomic pair transition prevent duplicate or orphan rows; transient transition failures retry three times | Runtime repository pair transition and sink retry path |
| Large tool output | Projection is bounded to 16,384 characters with an explicit truncation marker | Sink output bound |
| Cross-Thread information flow | Only the Agent's captured primary Workspace and its own private Thread are eligible | Sink Agent/workspace/source checks |
| Queue growth | Queue is capped at 256 activities per private Thread; completed-key memory is capped at 2,048 entries | Sink bounds |

The projector is enabled only when the injected runtime repository provides the atomic pair
transition. Unsupported custom repositories receive no projector rather than a split write.

The Linux focused test gate is currently blocked before compilation by SwiftPM's known resource-copy
I/O 22 failure for `PKLocalEmbeddingsTests/Fixtures`. The complete hosted gate remains authoritative
for the test rows above and for the provider/tool behavior matrix.

## Provisional release decision

Keep the projector internal and enabled only as an evaluation seam for the remainder of v4
development. Do not promise mirrored activity as supported runtime behavior, do not add an ADR, and
do not make it part of the RC contract. Before the v4 release candidate, record a final decision to
remove the default, make the seam explicitly opt-in, or remove the seam entirely based on prompt
growth and behavior-quality results.
