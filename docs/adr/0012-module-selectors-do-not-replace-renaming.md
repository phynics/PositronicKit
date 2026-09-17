---
status: accepted
---

# Module selectors do not replace renaming

Epic #192 adopts Swift 6.4, which ships SE-0491 module selectors to every supported toolchain.
Issue #198 asks whether that availability lowers the bar for renaming a public declaration that
collides with another name. It does not. PositronicKit keeps the naming rule in
[ADR 0008](0008-timeline-naming-hard-cut.md).

A module selector is written `Module::Name`. It exists so a caller can name a declaration from one
module when a local declaration or another import shadows the name. The caller must already know the
owning module and import it, so the selector only serves code that deliberately wants that module's
declaration. The default experience stays unqualified: a consumer writes `PKRuntime`,
`TimelineHandle`, and `PKTool` because #156 renamed away from the colliding spellings, and
`Scripts/check-v4-vocabulary.sh` still rejects a selective-import workaround for a first-party name.

SE-0491's own guidance says the same thing: an API design that forces clients to reach for a module
selector should usually be renamed instead. A selector cannot fix unqualified lookup, which is where
the original `Thread` collision hurt, and it is not a substitute for the naming rule.

Therefore module selectors do not lower the bar for future renames. They are a documented escape
hatch for a name PositronicKit does not control, such as `Foundation::Thread`, and
[the usage guide](../Usage.md#name-collisions) carries the consumer-facing spelling.
[ADR 0009](0009-prompt-dsl-keeps-swiftui-shaped-names.md) remains the one accepted deliberate
collision, and it resolves through `PKPrompt.ForEach` rather than a selector.
