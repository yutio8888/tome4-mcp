-- Contract tests for the P1a pure policy core: strict schema, the only way into
-- the critical self-preservation layer (emergency:true), the hp threshold
-- boundary, three-valued evaluation, and the attempt budget gate.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Schema=require 'mod.auto_combat.PolicySchema'
local Evaluator=require 'mod.auto_combat.PolicyEvaluator'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local function basePolicy()
    return {
        schema='tome-auto-combat/v1',id='p1',name='p1',
        updated='2026-01-01T00:00:00',
        limits={max_actions_per_tick=1},
        safety={min_hp_pct=35,flee_below_hp_pct=25,pause_on_new_enemy=true,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        rules={
            {id='heal-low',priority=100,emergency=true,
                when={hp_pct={lt=50}},['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
            {id='beam',priority=50,
                when={enemy_count={ge=1}},['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}},
        },
    }
end

-- 1. Strict schema -----------------------------------------------------------
check(Schema.validate(basePolicy()),'the baseline policy validates')
do
    local p=basePolicy();p.extra_field=1
    check(not Schema.validate(p),'unknown top-level field is rejected')
end
do
    local p=basePolicy();p.rules[1].when={mystery={lt=1}}
    check(not Schema.validate(p),'unknown predicate is rejected')
end
do
    local p=basePolicy();p.rules[1]['then']={action='teleport'}
    check(not Schema.validate(p),'unsupported action is rejected')
end
do
    local p=basePolicy();p.rules[1]['then']={action='use_talent',talent='T_NOT_ALLOWED'}
    check(not Schema.validate(p),'talent outside the P1a whitelist is rejected')
end
do
    local p=basePolicy();p.rules[1]['then'].target='far_hostile'
    check(not Schema.validate(p),'unsupported selector is rejected')
end
do
    local p=basePolicy();p.limits={max_actions_per_tick=5}
    check(not Schema.validate(p),'a policy cannot relax the hard attempt cap')
end
do
    local p=basePolicy();p.rules[2].id='heal-low'
    check(not Schema.validate(p),'duplicate rule ids are rejected')
end
do
    local p=basePolicy();p.safety.flee_below_hp_pct=90
    check(not Schema.validate(p),'flee threshold above min_hp_pct is rejected')
end
do
    local p=basePolicy();p.rules[1].emergency='yes'
    check(not Schema.validate(p),'emergency must be a boolean')
end

-- 2. Content hash ------------------------------------------------------------
do
    local a,b=basePolicy(),basePolicy()
    b.updated='2030-12-31T00:00:00'
    check(Schema.hash(a)==Schema.hash(b),'updated metadata does not change the content hash')
    b.rules[2].priority=51
    check(Schema.hash(a)~=Schema.hash(b),'a rule change changes the content hash')
    local reordered={}
    for _,rule in ipairs(a.rules) do reordered[#reordered+1]=rule end
    local c=basePolicy();c.rules={reordered[2],reordered[1]}
    check(Schema.hash(a)~=Schema.hash(c),'rule order is part of the hash')
end

-- 3. Critical threshold boundary --------------------------------------------
local function ctx(overrides)
    local c={attempts=0,enemy_count=1,hp_pct=80,
        resource_pct=function() return 100 end,
        resource_value=function() return 100 end}
    for k,v in pairs(overrides or {}) do c[k]=v end
    return c
end
local function ctxNoHp(overrides)
    local c=ctx(overrides); c.hp_pct=nil; return c
end
do
    local decision=Evaluator.evaluate(basePolicy(),ctx({hp_pct=80}))
    check(decision.decision=='act' and decision.rule=='beam','above the threshold uses normal output')
end
do
    -- hp 30 < min_hp_pct 35: normal output is forbidden even though 30 >= flee 25.
    local decision=Evaluator.evaluate(basePolicy(),ctx({hp_pct=30}))
    check(decision.decision=='act' and decision.rule=='heal-low' and decision.emergency,
        'below min_hp_pct only the emergency layer may act')
end
do
    local policy=basePolicy()
    policy.rules={policy.rules[2]}  -- no emergency rule
    local decision=Evaluator.evaluate(policy,ctx({hp_pct=30}))
    check(decision.decision=='pause' and decision.reason=='no_emergency_action',
        'critical state with no emergency action pauses instead of firing normal output')
end
do
    local decision=Evaluator.evaluate(basePolicy(),ctx({hp_pct=30,attempts=1}))
    check(decision.decision=='pause' and decision.reason=='budget_exhausted' and decision.critical,
        'exhausted budget pauses in critical state and never falls through to normal output')
end
do
    local decision=Evaluator.evaluate(basePolicy(),ctx({hp_pct=80,attempts=1}))
    check(decision.decision=='pause' and decision.reason=='budget_exhausted',
        'exhausted budget pauses in normal state too')
end

-- 4. Three-valued evaluation -------------------------------------------------
check(Evaluator.evalCondition({all={{always={}},{hp_pct={gt=10}}}},ctx())==Evaluator.TRUE,'all/true')
check(Evaluator.evalCondition({any={{hp_pct={gt=90}},{hp_pct={gt=10}}}},ctx())==Evaluator.TRUE,'any/true')
check(Evaluator.evalCondition({['not']={hp_pct={gt=90}}},ctx())==Evaluator.TRUE,'not/true')
check(Evaluator.evalCondition({hp_pct={gt=90}},ctxNoHp())==Evaluator.UNKNOWN,'missing value is unknown')
check(Evaluator.evalCondition({any={{hp_pct={gt=90}},{always={}}}},ctxNoHp())==Evaluator.TRUE,
    'unknown or true is true')
check(Evaluator.evalCondition({all={{hp_pct={gt=90}},{always={}}}},ctxNoHp())==Evaluator.UNKNOWN,
    'unknown and true is unknown')
do
    local policy=basePolicy()
    policy.rules={{id='resource-gated',priority=10,
        when={resource_pct={resource='positive',ge=50}},
        ['then']={action='use_talent',talent='T_BARRIER',target='self'}}}
    local decision=Evaluator.evaluate(policy,ctx({hp_pct=80,resource_pct=function() return nil end}))
    check(decision.decision=='pause' and decision.reason=='unknown_safety',
        'an unknown safety predicate pauses')
end

-- 5. Target binding ----------------------------------------------------------
do
    local policy=basePolicy()
    policy.rules={{id='finish',priority=10,
        when={enemy_hp_pct={lt=30}},
        ['then']={action='use_talent',talent='T_SEARING_LIGHT',target='lowest_hp_hostile'}}}
    local decision=Evaluator.evaluate(policy,ctx({hp_pct=80,enemy_hp_pct=20}))
    check(decision.decision=='act' and decision.target=='lowest_hp_hostile',
        'the decision target is the rule selector')
    local held=Evaluator.evaluate(policy,ctx({hp_pct=80,enemy_hp_pct=80}))
    check(held.decision=='hold','a rule that does not match holds')
end

print('Auto-combat policy: '..checks..' checks passed')
