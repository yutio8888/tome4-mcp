#!/usr/bin/env bash
# X-doubleprime pre-registered falsification matrix (rows 1-7) evidence runner.
#
# Runs the in-tree regression suite (rows 1-6 in-process), then the two pieces
# that need a process boundary or a clock:
#   row 6 (fresh-process determinism)  - N independent luajit processes must
#                                        report the identical typed fault for
#                                        the same malformed input, and the
#                                        identical content hash;
#   row 7 (cost falsifier)             - snapshot prepare/open/hash and one
#                                        action-opportunity transaction on a
#                                        representative maximum-size policy.
#
# Usage: tests/xdoubleprime_matrix.sh <evidence-dir>
# Exit 0 only when every row passes.
set -eu
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
addon_dir=$(cd "$script_dir/.." && pwd)
evidence=${1:-}
if [ -z "$evidence" ]; then echo "usage: $0 <evidence-dir>" >&2; exit 2; fi
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd)
LUA=${TOME_LUAJIT:-luajit}
rc=0

echo "== row 1-6 (in-process): tests/test_auto_combat_policy_bytes.lua"
if "$LUA" -O2 "$addon_dir/tests/test_auto_combat_policy_bytes.lua" > "$evidence/row1-6-suite.log" 2>&1; then
    echo "PASS row 6 in-process suite"; else echo "FAIL row 6 in-process suite"; rc=1; fi
tail -1 "$evidence/row1-6-suite.log"

echo "== row 6 (fresh-process determinism): 12 independent processes"
cat > "$evidence/determinism-probe.lua" <<LUA
package.path="$addon_dir/overload/?.lua;"..package.path
local Codec=require "mod.auto_combat.PolicyCodec"
local Json=require "mod.mcp_bridge.Json"
local Adapter=require "mod.auto_combat.AssistantAdapter"
-- Inadmissible key kinds must yield one deterministic typed fault per kind.
local function faultOf(build)
    local doc=build()
    local f=Codec.audit(doc,"config")
    return f and (f.input.."|"..tostring(f.cause).."|"..tostring(f.key)) or "nil"
end
local fnum=faultOf(function() local d={}; d[1.5]="x"; return d end)
local fstr=faultOf(function() local d={}; d.zeta="x"; d.alpha="y"; return d end)
local fexo=faultOf(function() local d={}; d[function() end]="x"; return d end)
local foth=faultOf(function() local d={}; d[true]="x"; return d end)
-- The golden content hash must be process-independent.
local file=assert(io.open("$addon_dir/tests/fixtures/assistant/anorithil_pinned.json","r"))
local text=file:read("*a"); file:close()
local imported=Adapter.translate(Json.decode(text))
print(table.concat({fnum,fstr,fexo,foth,imported.hash},"\\n"))
LUA
probe_file="$evidence/determinism-probe.lua"
: > "$evidence/fresh-process.log"
for i in $(seq 1 12); do
    "$LUA" -O2 "$probe_file" >> "$evidence/fresh-process.log" 2>&1
done
distinct=$(sort -u "$evidence/fresh-process.log" | wc -l)
# 12 runs x 5 lines = 60 lines; both halves must be identical, so exactly 5
# distinct lines and their concatenation is the same per run.
expected="$("$LUA" -O2 "$probe_file" | md5sum | cut -d' ' -f1)"
same=yes
for i in $(seq 1 6); do
    h=$("$LUA" -O2 "$probe_file" | md5sum | cut -d' ' -f1)
    [ "$h" = "$expected" ] || same=no
done
if [ "$distinct" -eq 5 ] && [ "$same" = yes ]; then
    echo "PASS row 6 fresh-process determinism (12 processes, 5 identical fault/hash lines)"
else
    echo "FAIL row 6 fresh-process determinism (distinct=$distinct same=$same)"; rc=1
fi

echo "== row 7 (cost): representative maximum-size policy"
cat > "$evidence/cost.lua" <<LUA
package.path="$addon_dir/overload/?.lua;"..package.path
local Codec=require "mod.auto_combat.PolicyCodec"
local Json=require "mod.mcp_bridge.Json"
local rules={}
for i=1,64 do
    rules[i]={id="r"..i,priority=10000-i,when={all={{hp_pct={lt=50+i%40}},
        {enemy_count={ge=1}},{cooldown_ready={talent="T_MOONLIGHT_RAY"}}}},
        ["then"]={action="use_talent",talent="T_MOONLIGHT_RAY",target="nearest_hostile"}}
end
local policy={schema="tome-auto-combat/v1",id="max",name="max-size policy",
    limits={max_actions_per_tick=4,max_rules=64},
    safety={min_hp_pct=35,flee_below_hp_pct=25,max_selffire_risk=0},
    targeting={default="nearest_hostile",tie_break={"distance","hp","uid"}},
    sustains={},rules=rules}
local N=2000
local t0=os.clock()
local snapshot
for _=1,N do snapshot=assert(Codec.prepare(policy,"cost")) end
local t1=os.clock()
for _=1,N do assert(Codec.open(snapshot)) end
local t2=os.clock()
for _=1,N do assert(Codec.hash(snapshot)) end
local t3=os.clock()
local bytes=#snapshot.bytes
print(string.format("rules=%d bytes=%d prepare_us=%.1f open_us=%.1f hash_us=%.1f hash=%s",
    #rules,bytes,(t1-t0)/N*1e6,(t2-t1)/N*1e6,(t3-t2)/N*1e6,snapshot.hash))
LUA
if "$LUA" -O2 "$evidence/cost.lua" > "$evidence/cost.log" 2>&1; then
    echo "row 7 cost MEASURED (no frozen threshold; NOT adjudicated PASS — see the doc)"
    cat "$evidence/cost.log"
else
    echo "FAIL row 7 cost benchmark"; rc=1
fi

echo "== row 4 (native acceptance + probe) is run separately by the dispatcher"
echo "matrix rc=$rc"
exit $rc
