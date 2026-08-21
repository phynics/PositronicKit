# Primary-Thread activity projection evaluation

Issue [#72](https://github.com/phynics/PositronicKit/issues/72) introduced a bounded internal
experiment that mirrored primary-Workspace tool activity from its source Thread into an Agent's
private Thread. It was never a public history contract.

## Final v4 decision

The experiment was removed before the 4.0 public API freeze. No consumer evidence demonstrated that
the extra prompt growth and hidden cross-Thread mutation improved behavior, and there was no narrow
opt-in contract that justified expanding the release surface.

For v4, tool activity is durable only on the Thread whose Turn executed it. Agent private-Thread
history changes through explicit Agent lifecycle and Turn operations. A future projection feature
would require its own issue, an explicit consumer story, bounded retention semantics, and an accepted
history contract.
