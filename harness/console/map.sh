#!/usr/bin/env bash
# Print the current local map as text rows (player is '@').
# Usage: map.sh
set -eu
dir=/workspace/t-engine4/tmp/mcp-play-support
"$dir/send.sh" '{"map":true}' | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("map unavailable:", e); sys.exit(0)
m = (d.get("result") or {})
rows = m.get("rows") or []
print("origin x=%s y=%s" % (m.get("x"), m.get("y")))
print("\n".join(rows))
'
