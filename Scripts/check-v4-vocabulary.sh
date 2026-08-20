#!/usr/bin/env bash
set -euo pipefail

# Current source and guidance must use the v4 Thread/Turn/Agent vocabulary. ADRs,
# the changelog, and exact glossary _Avoid_ lines are durable historical records;
# all other matches are actionable drift.
forbidden='(^|[^[:alnum:]_])(AgentInstance|agentInstance|ConversationMessage|conversationMessage|Timeline|timeline|ChatRun(Request|Error)?|ChatEvent|ChatEngine|ChatTurn|turnCount|maxTurns|roundTrip|sendID|sendId|timeline_(list|peek|send)|agentInstance(Id|ID)|timeline(Id|ID))([^[:alnum:]_]|$)'

matches=()
if command -v rg >/dev/null 2>&1; then
    scan_command=(rg -n --no-heading --color never "$forbidden" Sources Tests docs README.md llms.txt
        --glob '!docs/adr/**' --glob '!CHANGELOG.md')
else
    # The Linux verification image intentionally contains only the gate
    # prerequisites, so keep the checker usable without ripgrep as well.
    scan_command=(grep -RInE --binary-files=without-match --exclude=CHANGELOG.md "$forbidden"
        Sources Tests docs README.md llms.txt)
fi
while IFS= read -r match; do
    file=${match%%:*}
    remainder=${match#*:}
    line=${remainder%%:*}
    text=${remainder#*:}

    case "$file" in
        docs/adr/*|CHANGELOG.md)
            continue
            ;;
        Sources/PositronicKit/CONTEXT.md|Sources/PKPrompt/CONTEXT.md|Sources/PKContracts/CONTEXT.md)
            [[ "$text" == _Avoid_:* ]] && continue
            ;;
    esac

    matches+=("$file:$line:$text")
done < <("${scan_command[@]}" 2>/dev/null || true)

if ((${#matches[@]} > 0)); then
    printf '%s\n' "${matches[@]}" >&2
    printf 'v4 vocabulary check failed: retired terms found outside the historical/glossary allowlist.\n' >&2
    exit 1
fi

echo "v4 vocabulary check passed"
