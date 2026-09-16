#!/usr/bin/env bash
# Send one JSON command to a running ToME MCP agent console and print its result.
# The session MUST be given via TOME_AGENT_SESSION (use a session wrapper such as
# tome-insaneN.sh / map-insaneN.sh). A missing session fails fast instead of
# silently targeting another session.
#
# Each request carries a unique __rid and the wrapper waits for the reply that
# echoes it, so concurrent commands on one session can no longer cross streams.
# Usage: TOME_AGENT_SESSION=<session> send.sh '<json command>'
set -eu
dir=/workspace/t-engine4/tmp/mcp-play-support
S=${TOME_AGENT_SESSION:?set TOME_AGENT_SESSION (use a session wrapper like tome-insaneN.sh)}
cmd=${1:?usage: send.sh '<json command>'}
if [ ! -p "$dir/$S.cmd" ] || [ ! -f "$dir/$S.log" ]; then
    echo "{\"ok\":false,\"error\":\"unknown session $S: no FIFO/log. Set TOME_AGENT_SESSION to a running session.\"}"
    exit 2
fi
rid="r$$-$(date +%s%N 2>/dev/null || echo $RANDOM)"
merged=$(printf '%s' "$cmd" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["__rid"]=sys.argv[1]; print(json.dumps(d,separators=(",",":")))' "$rid")
before=$(wc -l < "$dir/$S.log")
printf '%s\n' "$merged" > "$dir/$S.cmd"
for _ in $(seq 1 6000); do
    line=$(tail -n +"$((before+1))" "$dir/$S.log" 2>/dev/null | grep -F '__rid' | grep -F "\"$rid\"" | tail -n 1 || true)
    if [ -n "$line" ]; then
        printf '%s\n' "$line"
        exit 0
    fi
    sleep 0.2
done
echo '{"ok":false,"error":"timeout waiting for console result"}'
exit 1
