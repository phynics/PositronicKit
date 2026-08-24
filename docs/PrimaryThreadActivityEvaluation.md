# Primary-Thread activity projection evaluation

Issue [#72](https://github.com/phynics/PositronicKit/issues/72) introduced a bounded internal
experiment that mirrored primary-Workspace tool activity from its source Thread into an Agent's
private Thread. It was never a public history contract.

## Reconciliation with current main

The initial audit was correct about the current checkout but incomplete about its history. PR
[#86](https://github.com/phynics/PositronicKit/pull/86) merged the experiment at
`a213244655b7389df135107fcb2c0ea78db42104`. Release-readiness PR
[#87](https://github.com/phynics/PositronicKit/pull/87) removed the sink before the public API
baseline and rewrote this evaluation as a final removal decision. The later Thread/workspace
cleanup (`9f8d7ee`) was separate and did not remove the activity sink.

The current `main` source tree, tests, public API baselines, and release records therefore agree:
there is no primary-Thread activity projector or internal delivery seam. `AgentActivitySink`
continues to receive lifecycle facts only; it does not mutate Thread history.
This reconciles the discrepancy tracked by issue [#93](https://github.com/phynics/PositronicKit/issues/93);
the final delivery records remain on issues [#72](https://github.com/phynics/PositronicKit/issues/72)
and [#75](https://github.com/phynics/PositronicKit/issues/75).

## Final v4 decision

The experiment was removed before the 4.0 public API freeze. No consumer evidence demonstrated that
the extra prompt growth and hidden cross-Thread mutation improved behavior, and there was no narrow
opt-in contract that justified expanding the release surface.

For v4, tool activity is durable only on the Thread whose Turn executed it. Agent private-Thread
history changes through explicit Agent lifecycle and Turn operations. A future projection feature
would require its own issue, an explicit consumer story, bounded retention semantics, and an accepted
history contract.
