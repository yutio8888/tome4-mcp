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

do
    -- The pilot preset's lowest-priority rule spends a turn on cooldown
    -- recovery instead of stopping every opportunity.
    local Presets=require 'mod.auto_combat.PolicyPresets'
    local preset=Presets.get('anorithil_p1a')
    local c=ctx({hp_pct=80,enemy_count=1,nearest_enemy_distance=5,enemy_in_melee=false,
        talent_known=function() return true end,
        cooldown_ready=function(id) return id~='T_MOONLIGHT_RAY' end})
    local decision=Evaluator.evaluate(preset,c)
    check(decision.decision=='act' and decision.rule=='recover' and decision.action=='wait',
        'the pilot preset waits one turn while its main ray cools down')
end

do
    -- Round-3 playtest soft-lock: an off-cooldown but unaffordable ray was
    -- selected, denied as native_rejected, and no rule matched, so the run
    -- stopped at `no_available_action` without spending a turn (the negative
    -- pool never regenerated). The ray must be resource-gated and the declared
    -- recovery must spend the turn instead.
    local Presets=require 'mod.auto_combat.PolicyPresets'
    local preset=Presets.get('anorithil_p1a')
    local broke=ctx({hp_pct=80,enemy_count=1,nearest_enemy_distance=5,enemy_in_melee=false,
        talent_known=function() return true end,
        cooldown_ready=function() return true end,
        resource_value=function(name) return name=='negative' and 5 or 100 end})
    local decision=Evaluator.evaluate(preset,broke)
    check(decision.decision=='act' and decision.rule=='recover' and decision.action=='wait',
        'the pilot preset waits when the ray is ready but the pool cannot pay')
    local paid=ctx({hp_pct=80,enemy_count=1,nearest_enemy_distance=5,enemy_in_melee=false,
        talent_known=function() return true end,
        cooldown_ready=function() return true end,
        resource_value=function(name) return name=='negative' and 25 or 100 end})
    local cast=Evaluator.evaluate(preset,paid)
    check(cast.decision=='act' and cast.rule=='ray' and cast.action=='use_talent',
        'the pilot preset casts the ray when the pool can pay for it')
end

-- P1b: native activities as first-class policy actions ----------------------
do
    local p=basePolicy()
    p.rules={{id='camp',priority=10,when={hp_pct={lt=50}},['then']={action='rest',max_turns=20}}}
    check(Schema.validate(p),'a rest rule with a bounded max_turns validates')
end
do
    local p=basePolicy()
    p.rules={{id='explore',priority=10,when={enemy_count={eq=0}},['then']={action='auto_explore'}}}
    check(Schema.validate(p),'an auto_explore rule validates')
    local bad=basePolicy()
    bad.rules={{id='explore',priority=10,when={always={}},['then']={action='auto_explore',talent='T_ATTACK'}}}
    check(not Schema.validate(bad),'auto_explore rejects a talent binding')
    local bad2=basePolicy()
    bad2.rules={{id='camp',priority=10,when={always={}},['then']={action='rest',target='self'}}}
    check(not Schema.validate(bad2),'rest rejects a target binding')
    local bad3=basePolicy()
    bad3.rules={{id='camp',priority=10,when={always={}},['then']={action='rest',max_turns=5000}}}
    check(not Schema.validate(bad3),'rest max_turns is bounded')
end
do
    -- Wave 1 (AC-10): change_level was removed from the auto-combat policy
    -- schema/claims; the general MCP tome.act action is unaffected.
    local p=basePolicy()
    p.rules={{id='descend',priority=10,when={enemy_count={eq=0}},['then']={action='change_level'}}}
    check(not Schema.validate(p),'change_level is no longer an auto-combat action')
    local permissions=basePolicy()
    permissions.permissions={change_level=true}
    check(not Schema.validate(permissions),'the permissions field is no longer accepted')
end
do
    -- The critical layer is only for self-preservation actions (shape); the
    -- catalogue certifies the specific talent (semantic).
    local p=basePolicy()
    p.rules={{id='panic-rest',priority=100,emergency=true,when={always={}},
        ['then']={action='rest',max_turns=5}}}
    check(not Schema.validate(p),'an emergency rest rule is rejected as non-self-preservation')
    local attack=basePolicy()
    attack.rules={{id='panic-attack',priority=100,emergency=true,when={always={}},
        ['then']={action='attack',target='nearest_hostile'}}}
    check(Schema.validate(attack),'an emergency attack is shape-valid; the executor guard is the safety gate')
end
do
    -- The evaluator carries max_turns into the act decision for the executor.
    local p=basePolicy();p.rules={{id='camp',priority=10,when={always={}},
        ['then']={action='rest',max_turns=7}}}
    local decision=Evaluator.evaluate(p,ctx({hp_pct=80,enemy_count=1}))
    check(decision.decision=='act' and decision.action=='rest' and decision.max_turns==7,
        'the evaluator returns the rest max_turns to the executor')
end

-- P2 audited target-selection predicates ------------------------------------
do
    local p=basePolicy()
    p.rules={{id='rank',priority=10,when={enemy_rank={ge=2}},
        ['then']={action='attack',target='nearest_hostile'}}}
    check(Schema.validate(p),'enemy_rank is schema-valid')
    check(Evaluator.evaluate(p,ctx({enemy_rank=2})).decision=='act','enemy_rank compares the bound target')
    check(Evaluator.evaluate(p,ctx({enemy_rank=1})).decision=='hold','enemy_rank below the threshold holds')

    p.rules={{id='level',priority=10,when={enemy_level={le=5}},
        ['then']={action='attack',target='nearest_hostile'}}}
    check(Schema.validate(p),'enemy_level is schema-valid')
    check(Evaluator.evaluate(p,ctx({enemy_level=3})).decision=='act','enemy_level compares')

    p.rules={{id='type',priority=10,when={enemy_type={eq='undead'}},
        ['then']={action='attack',target='nearest_hostile'}}}
    check(Schema.validate(p),'enemy_type is schema-valid')
    check(Evaluator.evaluate(p,ctx({enemy_type='undead'})).decision=='act','enemy_type matches')
    check(Evaluator.evaluate(p,ctx({enemy_type='animal'})).decision=='hold','enemy_type mismatch holds')
    check(Evaluator.evaluate(p,ctx({enemy_type=nil})).decision=='hold','enemy_type unknown holds')

    p.rules={{id='dist',priority=10,when={enemy_distance={le=3}},
        ['then']={action='attack',target='nearest_hostile'}}}
    check(Schema.validate(p),'enemy_distance is schema-valid')
    check(Evaluator.evaluate(p,ctx({enemy_distance=2})).decision=='act','enemy_distance compares the bound target')

    local bad=basePolicy()
    bad.rules={{id='bad',priority=10,when={enemy_type={lt=3}},
        ['then']={action='attack',target='nearest_hostile'}}}
    check(not Schema.validate(bad),'enemy_type rejects a numeric comparison')
end

do
    -- P2 per-selector condition evaluation: a target-specific condition is
    -- checked against the selector the action will bind, not the default one.
    local p=basePolicy()
    p.rules={{id='boss',priority=10,when={enemy_is_boss={}},
        ['then']={action='use_talent',talent='T_SUN_BEAM',target='most_dangerous_hostile'}}}
    local near_ctx=ctx({hp_pct=80,enemy_count=2,enemy_rank=2})
    local boss_ctx=ctx({hp_pct=80,enemy_count=2,enemy_rank=4})
    local decision=Evaluator.evaluate(p,near_ctx,{context_for=function(selector)
        if selector=='most_dangerous_hostile' then return boss_ctx end
        return near_ctx
    end})
    check(decision.decision=='act' and decision.rule=='boss' and decision.target=='most_dangerous_hostile',
        'context_for evaluates the condition against the action selector')
    check(Evaluator.evaluate(p,near_ctx).decision=='hold',
        'without context_for the default binding applies')
end

-- P2.5: tooltip-safe getter predicates --------------------------------------
do
    -- `computed` is a numeric comparison over a finite enum.
    local p=basePolicy()
    p.rules={{id='resist',priority=10,when={computed={field='resists.DARKNESS',ge=50}},
        ['then']={action='wait'}}}
    check(Schema.validate(p),'a finite-enum computed predicate is schema-valid')
    local ctxc=ctx({hp_pct=80,enemy_count=1,
        computed=function(field) return field=='resists.DARKNESS' and 60 or nil end})
    check(Evaluator.evaluate(p,ctxc).decision=='act','computed compares numerically')
    local low=ctx({hp_pct=80,enemy_count=1,
        computed=function(field) return field=='resists.DARKNESS' and 10 or nil end})
    check(Evaluator.evaluate(p,low).decision=='hold','computed below the threshold holds')
    local missing=ctx({hp_pct=80,enemy_count=1,computed=function() return nil end})
    check(Evaluator.evaluate(p,missing).decision=='hold','an unknown computed getter is unknown, not true')

    local bad=basePolicy()
    bad.rules={{id='bad',priority=10,when={computed={field='arbitrary.path',gt=1}},
        ['then']={action='wait'}}}
    check(not Schema.validate(bad),'an arbitrary computed path is rejected')
    local noCmp=basePolicy()
    noCmp.rules={{id='bad',priority=10,when={computed={field='crit.spell'}},
        ['then']={action='wait'}}}
    check(not Schema.validate(noCmp),'computed requires exactly one comparison')
    local badCmp=basePolicy()
    badCmp.rules={{id='bad',priority=10,when={computed={field='crit.spell',contains=1}},
        ['then']={action='wait'}}}
    check(not Schema.validate(badCmp),'computed rejects a non-numeric comparator')
end

do
    -- `has_effect` accepts who in {self,target} and requires a bounded string.
    local p=basePolicy()
    p.rules={{id='eff',priority=10,when={has_effect={effect='EFF_TEST',who='target'}},
        ['then']={action='wait'}}}
    check(Schema.validate(p),'has_effect accepts who=target')
    p.rules[1].when={has_effect={effect='EFF_TEST'}}
    check(Schema.validate(p),'has_effect defaults who=self')
    p.rules[1].when={has_effect={effect='EFF_TEST',who='pet'}}
    check(not Schema.validate(p),'has_effect rejects an unknown who')
    p.rules[1].when={has_effect={effect=''}}
    check(not Schema.validate(p),'has_effect rejects an empty effect')

    local c=ctx({hp_pct=80,enemy_count=1,has_effect=function(effect,who)
        return who=='target' and effect=='EFF_TEST' end})
    local pe=basePolicy()
    pe.rules={{id='eff',priority=10,when={has_effect={effect='EFF_TEST',who='target'}},
        ['then']={action='wait'}}}
    check(Evaluator.evaluate(pe,c).decision=='act','has_effect reads the bound target')
    local unknown=ctx({hp_pct=80,enemy_count=1,has_effect=function() return nil end})
    check(Evaluator.evaluate(pe,unknown).decision=='hold','an unavailable effect list is unknown')
end

do
    local p=basePolicy()
    p.rules={{id='allies',priority=10,when={ally_count={ge=2}},
        ['then']={action='wait'}}}
    check(Schema.validate(p),'ally_count is schema-valid')
    check(Evaluator.evaluate(p,ctx({hp_pct=80,enemy_count=1,ally_count=3})).decision=='act',
        'ally_count compares the visible ally count')
    check(Evaluator.evaluate(p,ctx({hp_pct=80,enemy_count=1,ally_count=1})).decision=='hold',
        'ally_count below the threshold holds')
end

-- INT-03: strict union validation (no silently ignored extras).
do
    local bad=basePolicy();bad.logging={ring_size=256,extra=true}
    check(not Schema.validate(bad),'logging rejects an unknown field')
    bad=basePolicy();bad.logging={ring_size='256'}
    check(not Schema.validate(bad),'logging.ring_size must be an integer')
    bad=basePolicy();bad.targeting.tie_break={'distance','nonsense'}
    check(not Schema.validate(bad),'targeting.tie_break rejects an unknown key')
    bad=basePolicy();bad.rules[1].when={all={{always={}}},extra=true}
    check(not Schema.validate(bad),'a composite condition rejects extra keys')
    bad=basePolicy();bad.rules[1].when={always={},extra={}}
    check(not Schema.validate(bad),'a predicate leaf rejects extra keys')
    bad=basePolicy();bad.rules[1]['then']={action='wait',talent='T_ATTACK'}
    check(not Schema.validate(bad),'wait rejects an irrelevant talent')
    bad=basePolicy();bad.rules[1]['then']={action='wait',target='self'}
    check(not Schema.validate(bad),'wait rejects an irrelevant target')
    bad=basePolicy();bad.rules[1]['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self',max_turns=3}
    check(not Schema.validate(bad),'use_talent rejects max_turns')
    bad=basePolicy();bad.rules[1]['then']={action='attack',target='nearest_hostile',talent='T_ATTACK'}
    check(not Schema.validate(bad),'attack rejects an irrelevant talent')
    local ok=basePolicy();ok.logging={ring_size=256,log_rejections=true};ok.targeting.tie_break={'distance','hp','uid'}
    check(Schema.validate(ok),'valid logging and tie_break are accepted')
end

print('Auto-combat policy: '..checks..' checks passed')
