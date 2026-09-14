#!/usr/bin/env bash
set -euo pipefail

# Timeline is the live Swift vocabulary. This checker protects the #156 hard cut by rejecting
# retired Thread names in current code and documentation. Legacy spellings are permitted only
# when the owning file and exact line pattern are recorded in v4-drift-allowlist.txt.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="$ROOT/Scripts/v4-drift-allowlist.txt"

# All path matching below is intentionally repository-relative so the checker behaves the same
# when invoked directly, from Make, or by a CI wrapper.
cd "$ROOT"

is_historical_path() {
    case "$1" in
        docs/adr/000[1-7]-*.md|docs/stable/*|docs/TicketAssessment150-151.md) return 0 ;;
        *) return 1 ;;
    esac
}

is_released_changelog_line() {
    local file="$1" line="$2" first_release
    [[ "$file" == CHANGELOG.md ]] || return 1
    first_release=$(awk '/^## \[[0-9]/{print NR; exit}' "$ROOT/CHANGELOG.md")
    [[ -n "$first_release" && "$line" -ge "$first_release" ]]
}

is_allowlisted() {
    local file="$1" text="$2" path_pattern pattern
    while IFS='|' read -r path_pattern pattern; do
        [[ -z "${path_pattern//[[:space:]]/}" || "${path_pattern:0:1}" == "#" ]] && continue
        if [[ "$file" == $path_pattern ]] && [[ "$text" =~ $pattern ]]; then
            return 0
        fi
    done < "$ALLOWLIST"
    return 1
}

# Match the retired word in prose and all source-level derived forms. The underscore-delimited
# model identifiers are listed separately so they can be allowed only at their wire boundaries.
# Keep the earlier v4 drift guards here too: the Timeline hard cut must not reopen the rejected
# conversation/chat/instance vocabulary or introduce parallel `timeline_*` model entry points.
forbidden='(^|[^[:alnum:]_])thread([^[:alnum:]_]|$)|privateThread|runtimeThread|forThread|Thread[A-Z]|thread[A-Z]|thread_(list|peek|send|id)|agentinstance|agent[[:space:]]+instance|conversation(message|msg|id)|observableconversation|chatrun(request|error)?|chatevent|chatengine|chat[[:space:]]+engine|chatturn|(^|[^[:alnum:]_])chat[[:space:]]+turn([^[:alnum:]_]|$)|runchatloop|llmchatrequest|chatstreamwithcontext|chatrequesthistory|lastchatrequest|chatcapturehistory|lastchatcapture|chat[-[:space:]]+loop|chat[-[:space:]]+stream|createinstance|deleteinstance|getinstance|listinstances|updateinstances|searchinstances|instancenotfound|sendid|send[[:space:]]+id|send[[:space:]]+identifier|send[[:space:]]+reservation|pkerrordomain\.chat|com\.positronickit\.core\.chat|turncount|maxturns|(^|[^[:alnum:]_])max[-[:space:]]+turns?([^[:alnum:]_]|$)|(^|[^[:alnum:]_])turn[-[:space:]]+count([^[:alnum:]_]|$)|timeline_(list|peek|send)'
matches=()

while IFS= read -r match; do
    file=${match%%:*}
    remainder=${match#*:}
    line=${remainder%%:*}
    text=${remainder#*:}

    is_historical_path "$file" && continue
    is_released_changelog_line "$file" "$line" && continue

    if ! is_allowlisted "$file" "$text"; then
        matches+=("$file:$line:$text")
    fi
done < <(
    grep -RIniE --binary-files=without-match \
        --exclude=check-v4-vocabulary.sh \
        --exclude=v4-drift-allowlist.txt \
        "$forbidden" \
        Sources Tests docs Scripts .github README.md AGENTS.md CONTEXT-MAP.md CHANGELOG.md Package.swift llms.txt \
        2>/dev/null || true
)

# The semantic scan cannot catch a retired term that survives only in a filename. Historical
# material is immutable, but active source/test-support filenames may not retain Thread names.
while IFS= read -r path; do
    case "$path" in
        docs/adr/*|docs/stable/*|CHANGELOG.md) continue ;;
    esac
    basename=${path##*/}
    if printf '%s\n' "$basename" | grep -qiE '(^|[^[:alnum:]_])thread(\.|[[:alnum:]_]|$)|privateThread|runtimeThread'; then
        matches+=("$path:filename:$basename")
    fi
done < <(cd "$ROOT" && find Sources Tests docs Scripts .github -type f -print 2>/dev/null)

# Compatibility aliases would reintroduce a retired public entry point even when hidden behind a
# neutral filename. Search only live Swift so historical prose cannot weaken this guard.
while IFS= read -r match; do
    matches+=("$match")
done < <(
    grep -RInE --include='*.swift' \
        'typealias[[:space:]]+(PositronicKit|Thread|ThreadHandle|ThreadCapability|ThreadController|ThreadPersistenceProtocol|ThreadMessageStoreProtocol|ThreadRuntimeRepository|ThreadMessage|ThreadSummary|ThreadContext|ThreadError|ThreadDeletionResult|Tool|PKOpenAIProvider|PKOpenRouterProvider|PKOllamaProvider|PKAnthropicProvider)[[:space:]]*=' \
        Sources Tests 2>/dev/null || true
)

# TimelineHandle has one public admission surface. Reject an unqualified/internal/private
# duplicate of a canonical entry point (including the old implicit-internal `send`/`run` forms)
# so a second execution path cannot quietly return during the hard cut.
timeline_handle="$ROOT/Sources/PositronicKit/Timelines/TimelineHandle.swift"
if [[ -f "$timeline_handle" ]]; then
    while IFS= read -r match; do
        matches+=("$timeline_handle:duplicate-entry-point:$match")
    done < <(
        grep -nE '^[[:space:]]*(internal[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+)?func[[:space:]]+(send|run|startTurn|startDirectTurn)([[:space:](<]|$)' "$timeline_handle" || true
    )
fi

if ((${#matches[@]} > 0)); then
    printf '%s\n' "${matches[@]}" >&2
    printf 'v4 vocabulary check failed: retired vocabulary, duplicate entry point, or compatibility alias found.\n' >&2
    exit 1
fi

echo "v4 vocabulary check passed"
