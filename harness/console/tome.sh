#!/usr/bin/env bash
# Send one JSON command to the ToME MCP console and print a COMPACT result.
#
# Compared with the raw MCP response this:
#   * drops map rows (use map.sh to view them),
#   * turns the repeated "last ~12 log lines" events page into an INCREMENTAL
#     stream: only entries newer than the last cursor are kept, tracked in
#     <session>.events-cursor,
#   * strips ToME colour markup (#GREY#, #{bold}#, #UID:..:..#, ...) from log text,
#   * reports how many events were missed if a single action produced more log
#     lines than the bridge's default page window.
#
# Usage: tome.sh '<json command>'
set -eu
dir=/workspace/t-engine4/tmp/mcp-play-support
S=${TOME_AGENT_SESSION:-agent-ham-madness-01}
exec "$dir/send.sh" "${1:?usage: tome.sh '<json>'}" | TOME_AGENT_SESSION="$S" python3 -c '
import json, os, re, sys

S = os.environ.get("TOME_AGENT_SESSION", "agent-ham-madness-01")
cursor_file = "/workspace/t-engine4/tmp/mcp-play-support/%s.events-cursor" % S
try:
    last = int(open(cursor_file).read().strip())
except Exception:
    last = 0
seen = set()
head_seen = last

TAG = re.compile(r"#(?:UID:[^#]*|[A-Za-z0-9_{}:]+)#")
def clean_text(t):
    if not isinstance(t, str):
        return t
    t = TAG.sub("", t).replace("##", "")
    return t.strip()

def dedupe_events(ev):
    global head_seen
    if not isinstance(ev, dict):
        return ev
    head = ev.get("head_cursor") or 0
    entries = []
    for e in ev.get("entries") or []:
        c = e.get("cursor") or 0
        if c <= last or c in seen:
            continue
        seen.add(c)
        if "text" in e:
            e = dict(e)
            e["text"] = clean_text(e["text"])
        entries.append(e)
    head_seen = max(head_seen, head)
    out = {k: v for k, v in ev.items() if k != "entries"}
    out["entries"] = entries
    out["new"] = len(entries)
    if entries:
        first = entries[0].get("cursor") or 0
        missed = first - last - 1 if first > last + 1 else 0
        if missed > 0:
            out["missed_before"] = missed
    return out

def fix(o):
    if isinstance(o, dict):
        out = {}
        for k, v in o.items():
            if k == "events":
                out["events"] = dedupe_events(v)
            elif k == "map" and isinstance(v, dict):
                out["map"] = {kk: vv for kk, vv in v.items() if kk != "rows"}
            else:
                out[k] = fix(v)
        return out
    if isinstance(o, list):
        return [fix(x) for x in o]
    return o

raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    print(raw); sys.exit(0)

result = fix(d)

# Advance the cursor once per command, after all events objects were deduped.
if head_seen > last:
    try:
        with open(cursor_file, "w") as fh:
            fh.write(str(head_seen))
    except Exception:
        pass

print(json.dumps(result, ensure_ascii=False))
'
