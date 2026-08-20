---
status: accepted
---

# Thread-addressed Agent execution

The v4 execution model addresses managed execution to a Thread and derives its Agent from the
Thread attachment; detached Threads may use an explicit direct Turn with consumer-supplied context.
We reject callable Agents and optional Agent IDs on Turn requests because Agent continuity and
authority belong to the Thread execution context, while the direct path preserves an intentional
escape hatch without inventing hidden Agent state.
