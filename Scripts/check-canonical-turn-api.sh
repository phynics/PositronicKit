#!/usr/bin/env bash

set -u

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
failures=0

check_absent() {
    local pattern="$1"
    shift
    if rg -n -- "$pattern" "$@"; then
        printf 'Unexpected canonical Turn API match: %s\n' "$pattern" >&2
        failures=1
    fi
}

check_present() {
    local pattern="$1"
    shift
    if ! rg -n -- "$pattern" "$@" >/dev/null; then
        printf 'Missing canonical Turn API match: %s\n' "$pattern" >&2
        failures=1
    fi
}

thread_handle="$ROOT/Sources/PositronicKit/Threads/ThreadHandle.swift"
turn_request="$ROOT/Sources/PositronicKit/Models/Turn/TurnRequest.swift"
current_docs=(
    "$ROOT/README.md"
    "$ROOT/docs/Usage.md"
    "$ROOT/Sources/PositronicKit/PositronicKit.docc/ArchitectureOverview.md"
    "$ROOT/Sources/PositronicKit/PositronicKit.docc/PositronicKit.md"
)

check_absent '^    internal func (send|run|startTurn|startDirectTurn)\b' "$thread_handle"
check_absent '^public struct TurnRequest\b' "$turn_request"
check_absent 'thread\.send\(|ThreadHandle\.run\(|startDirectTurn\(message:' "${current_docs[@]}"
check_present 'public func startTurn\(' "$thread_handle"
check_present 'public func startDirectTurn\(' "$thread_handle"

exit "$failures"
