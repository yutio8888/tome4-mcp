-- A/B tuning harness on fixed scenarios (design §15 P2 row).
--
-- Compares the frozen Anorithil preset against a tuned variant that adds a
-- rank-aware boss rule built from the P2 audited reads. The harness runs pure
-- evaluator scenarios, so the result is deterministic and engine-free.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/?.lua;'..root..'/overload/?.lua;'..package.path
local AB=require 'tests.auto_combat_ab'
local Presets=require 'mod.auto_combat.PolicyPresets'
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end
local function clone(value)
    if type(value)~='table' then return value end
    local out={}
    for k,v in pairs(value) do out[k]=clone(v) end
    return out
end

-- Fixed scenarios. Each has a default-selector context and, where a rule binds
-- a different selector, a per-selector context so the condition is evaluated
-- against the same target the action would use.
local function normal(overrides)
    local ctx={hp_pct=80,enemy_count=1,enemy_in_melee=false,nearest_enemy_distance=5,
        enemy_hp_pct=80,enemy_rank=2,enemy_level=10,enemy_type='animal',enemy_distance=5,
        talent_known=function() return true end,cooldown_ready=function() return true end,
        resource_pct=function() return 100 end,resource_value=function() return 100 end,
        attempts=0}
    for k,v in pairs(overrides or {}) do ctx[k]=v end
    return ctx
end
local boss=normal({enemy_rank=4,enemy_level=30,enemy_type='undead',enemy_distance=8,
    enemy_hp_pct=70,hp_pct=80})
local nearest=normal({enemy_hp_pct=80,enemy_rank=2,enemy_distance=4})

local scenarios={
    {id='low-hp',ctx=normal({hp_pct=20})},
    {id='boss-visible',ctx=nearest,selectors={most_dangerous_hostile=boss}},
    {id='no-enemy',ctx={hp_pct=80,enemy_count=0,enemy_in_melee=false,attempts=0,
        talent_known=function() return true end,cooldown_ready=function() return true end,
        resource_pct=function() return 100 end,resource_value=function() return 100 end}},
    {id='ray-cooldown',ctx=normal({cooldown_ready=function(id) return id~='T_MOONLIGHT_RAY' end})},
}

-- Baseline is the frozen P1a pilot preset. The tuned policy adds one data-only
-- boss rule (priority between barrier and finish) using `enemy_is_boss` and
-- `most_dangerous_hostile`; nothing else changes.
local baseline=Presets.copy('anorithil_p1a')
local tuned=clone(baseline)
tuned.id='anorithil-p2-tuned'
table.insert(tuned.rules,3,{id='boss',priority=85,
    when={all={{enemy_is_boss={}},{talent_known={talent='T_MOONLIGHT_RAY'}},
        {cooldown_ready={talent='T_MOONLIGHT_RAY'}}}},
    ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='most_dangerous_hostile'}})

check(Schema.validate(baseline)==true,'the baseline preset validates')
check(Catalog.verify(baseline)==true,'the baseline preset is catalogue-compatible')
check(Schema.validate(tuned)==true,'the tuned policy validates')
check(Catalog.verify(tuned)==true,'the tuned policy is catalogue-compatible')

local rows=AB.run(scenarios,{{name='baseline',policy=baseline},{name='tuned',policy=tuned}})
check(#rows==#scenarios*2,'the harness runs every scenario for both policies')
local differences=AB.differences(rows)
check(#differences==1 and differences[1].scenario=='boss-visible',
    'only the boss scenario diverges between the two policies')

local byKey={}
for _,row in ipairs(rows) do byKey[row.scenario..'/'..row.policy]=row end
check(byKey['boss-visible/baseline'].rule=='ray' and byKey['boss-visible/baseline'].decision=='act',
    'the baseline spends the boss turn on the nearest hostile')
check(byKey['boss-visible/tuned'].rule=='boss'
    and byKey['boss-visible/tuned'].target=='most_dangerous_hostile',
    'the tuned policy focuses the highest-rank hostile')
check(byKey['low-hp/baseline'].decision==byKey['low-hp/tuned'].decision,
    'the tuning does not change the emergency heal decision')
check(byKey['ray-cooldown/baseline'].rule=='recover' and byKey['ray-cooldown/tuned'].rule=='recover',
    'both policies fall back to the declared cooldown recovery')

-- Record the evidence summary (small JSON under tmp/, never committed raw).
os.execute('mkdir -p tmp/tome-mcp-ab')
local report={scenarios={},rows=rows,differences={}}
for _,scenario in ipairs(scenarios) do report.scenarios[#report.scenarios+1]=scenario.id end
for _,diff in ipairs(differences) do
    report.differences[#report.differences+1]={scenario=diff.scenario,rows=diff.rows}
end
local file=io.open('tmp/tome-mcp-ab/report.json','w')
if file then file:write(Json.encode(report));file:close() end

print('Auto-combat A/B: '..checks..' checks passed; divergent scenarios: '
    ..#differences..' ('..(differences[1] and differences[1].scenario or 'none')..')')
