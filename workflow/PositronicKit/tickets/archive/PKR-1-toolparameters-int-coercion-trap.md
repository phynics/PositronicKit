# PKR-1 — `ToolParameters` Int coercion can crash the process or silently truncate

**Status:** Done — replaced the trapping `Int(doubleVal)` in `require`/`optional` with `doubleVal.isFinite` + `Int(exactly:)` (nil for out-of-range/fractional, succeeds for integer-valued like `4.0`); `require` throws `ToolError.invalidArgument` on failure, `optional` returns nil. Strict (throw on fractional) per the type's precise-error doc contract. 10 new tests; `swift test` green (628).
**Severity:** 🔴 High (LLM-supplied input can trap at runtime)
**Repos:** PositronicKit (PKShared)
**Source:** PositronicKit review 2026-07-02

## Problem

`Sources/PKShared/Tools/ToolParameters.swift:33` (`require`) and `:55-56` (`optional`) call
`Int(doubleVal)` — the **trapping** initializer — on any Double argument when `T == Int`
(verified; the `as? T` cast happens after the trap). An LLM-supplied tool argument like `1e30`,
`NaN`, or `Infinity` crashes the whole process instead of throwing `ToolError.invalidArgument`.
In-range fractional values (e.g. `4.7`) are silently truncated to `4`, violating the "precise
error reporting" contract in the type's doc comment (`:5-19`). No test exercises the
numeric-conversion path (`Tests/PKSharedTests/Tools/ToolParametersTests.swift`).

## Suggested direction

Guard with `Int(exactly:)` / finiteness + range checks; throw `ToolError.invalidArgument` for
non-finite, out-of-range, or fractional doubles (or document+keep truncation, but never trap).
Add tests: large/NaN/Infinity/fractional doubles on both `require` and `optional`.
