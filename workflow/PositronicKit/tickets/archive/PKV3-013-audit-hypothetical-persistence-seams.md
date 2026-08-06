# PKV3-013 — Audit and remove hypothetical persistence seams

**Priority:** P2
**Type:** Dead-code / interface audit
**Depends on:** —
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done

## Summary

Delete zero-consumer persistence protocols or prove each retained seam with a real consumer, concrete adapter, and contract test.

## Implementation Requirements

- Audit `AgentInstanceStoreProtocol` and `RequestOriginStoreProtocol` across PositronicKit, Monad, Shuttle, and Yakamoz.
- Delete a protocol with no real consumer, together with mocks/tests/docs.
- For a retained protocol, document its consumer and adapter and add a contract test.
- Do not retain a public protocol for hypothetical future extensibility.

## Acceptance Criteria

- [ ] Audit evidence is recorded in this ticket.
- [ ] Every surviving protocol has a real consumer, concrete adapter, and contract test.
- [ ] Zero-consumer protocols and their dead support code are removed.
- [ ] Package and consumer gates pass.

