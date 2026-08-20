#!/usr/bin/env bash
set -euo pipefail

# Current source and guidance must use the v4 Thread/Turn/Agent vocabulary. ADRs,
# the changelog, and exact glossary _Avoid_ lines are durable historical records;
# all other matches are actionable drift. Keep this list case-insensitive so that
# prose, camel-case identifiers, and logger labels are checked consistently.
forbidden='agentinstance|agent[[:space:]]+instance|conversation(message|msg|id)|observableconversation|timeline|chatrun(request|error)?|chatevent|chatengine|chat[[:space:]]+engine|chatturn|(^|[^[:alnum:]_])chat[[:space:]]+turn([^[:alnum:]_]|$)|runchatloop|llmchatrequest|chatstreamwithcontext|chatrequesthistory|lastchatrequest|chatcapturehistory|lastchatcapture|chat[-[:space:]]+loop|chat[-[:space:]]+stream|createinstance|deleteinstance|getinstance|listinstances|updateinstance|searchinstances|instancenotfound|sendid|send[[:space:]]+id|send[[:space:]]+identifier|send[[:space:]]+reservation|pkerrordomain\.chat|com\.positronickit\.core\.chat|turncount|maxturns|(^|[^[:alnum:]_])max[-[:space:]]+turns?([^[:alnum:]_]|$)|(^|[^[:alnum:]_])turn[-[:space:]]+count([^[:alnum:]_]|$)|timeline_(list|peek|send)|agentinstance(id|ID)|timeline(id|ID)'

matches=()
scan_command=(grep -RIniE --binary-files=without-match --exclude=CHANGELOG.md "$forbidden"
    Sources Tests docs README.md llms.txt)
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
done < <(find Sources Tests docs -type f -print 2>/dev/null)

if ((${#matches[@]} > 0)); then
    printf '%s\n' "${matches[@]}" >&2
    printf 'v4 vocabulary check failed: retired terms found outside the historical/glossary allowlist.\n' >&2
    exit 1
fi

echo "v4 vocabulary check passed"
