#!/usr/bin/env bash
set -euo pipefail

# Current source, tests, package metadata, automation, and guidance must use the
# v4 Thread/Turn/Agent vocabulary. Historical exceptions live in one reviewed,
# path-and-line-scoped allowlist. Keep this list case-insensitive so prose,
# serialized keys, tool names, identifiers, logger labels, and paths agree.
forbidden='agentinstance|agent[[:space:]]+instance|conversation(message|msg|id)|observableconversation|timeline|chatrun(request|error)?|chatevent|chatengine|chat[[:space:]]+engine|chatturn|(^|[^[:alnum:]_])chat[[:space:]]+turn([^[:alnum:]_]|$)|runchatloop|llmchatrequest|chatstreamwithcontext|chatrequesthistory|lastchatrequest|chatcapturehistory|lastchatcapture|chat[-[:space:]]+loop|chat[-[:space:]]+stream|createinstance|deleteinstance|getinstance|listinstances|updateinstance|searchinstances|instancenotfound|sendid|send[[:space:]]+id|send[[:space:]]+identifier|send[[:space:]]+reservation|pkerrordomain\.chat|com\.positronickit\.core\.chat|turncount|maxturns|(^|[^[:alnum:]_])max[-[:space:]]+turns?([^[:alnum:]_]|$)|(^|[^[:alnum:]_])turn[-[:space:]]+count([^[:alnum:]_]|$)|timeline_(list|peek|send)|agentinstance(id|ID)|timeline(id|ID)'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="$ROOT/Scripts/v4-drift-allowlist.txt"

is_allowlisted() {
    local candidate_file="$1"
    local candidate_text="$2"
    local allowed_file allowed_pattern
    while IFS='|' read -r allowed_file allowed_pattern; do
        [[ -z "$allowed_file" || "$allowed_file" == \#* ]] && continue
        if [[ "$candidate_file" == "$allowed_file" ]] && printf '%s\n' "$candidate_text" | grep -qE "$allowed_pattern"; then
            return 0
        fi
    done < "$ALLOWLIST"
    return 1
}

cd "$ROOT"
matches=()
changelog_unreleased_end=$(awk '/^## \[[0-9]/{print NR; exit}' CHANGELOG.md)
scan_command=(grep -RIniE --binary-files=without-match
    --exclude=check-v4-vocabulary.sh --exclude=v4-drift-allowlist.txt "$forbidden"
    Sources Tests docs Scripts .github README.md AGENTS.md CONTEXT-MAP.md CHANGELOG.md Package.swift llms.txt)
while IFS= read -r match; do
    file=${match%%:*}
    remainder=${match#*:}
    line=${remainder%%:*}
    text=${remainder#*:}

    # Tagged release notes are immutable history. Scan the live Unreleased section, then stop at
    # the first version heading so newly added notes remain governed without rewriting old tags.
    if [[ "$file" == "CHANGELOG.md" && "$line" -ge "$changelog_unreleased_end" ]]; then
        continue
    fi

    is_allowlisted "$file" "$text" && continue

    matches+=("$file:$line:$text")
done < <("${scan_command[@]}" 2>/dev/null || true)

# The semantic scan above cannot see a retired term that survives only in a
# filename. Check basenames separately so helper/type files cannot preserve the
# old vocabulary while their contents happen to be neutral.
while IFS= read -r path; do
    case "$path" in
        docs/adr/*|*CHANGELOG.md)
            continue
            ;;
    esac
    basename=${path##*/}
    if printf '%s\n' "$basename" | grep -qiE 'agentinstance|timeline|chat(engine|run|turn)|chatstreamresultfactory|conversation(message|msg|id)|observableconversation'; then
        matches+=("$path:filename:$basename")
    fi
done < <(find Sources Tests docs Scripts .github -type f -print 2>/dev/null)

if ((${#matches[@]} > 0)); then
    printf '%s\n' "${matches[@]}" >&2
    printf 'v4 vocabulary check failed: retired terms found outside the historical/glossary allowlist.\n' >&2
    exit 1
fi

echo "v4 vocabulary check passed"
