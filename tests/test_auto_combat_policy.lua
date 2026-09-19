-- Contract tests for the P1a pure policy core: strict schema, the only way into
-- the critical self-preservation layer (emergency:true), the hp threshold
-- boundary, three-valued evaluation, and the attempt budget gate.
-- P3-b (TODO #63): derive the addon root from this test's own path so a bare
-- relative invocation fails loudly instead of silently testing the canonical
-- `game/addons/tome-mcp-bridge` tree from another checkout.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
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
    -- v1.6 (D5 supersession, MOV-5): `change_level` is re-admitted as an
    -- ordinary capability-backed policy action. The `permissions` top-level
    -- field remains gone (it was never a capability grant).
    local p=basePolicy()
    p.rules={{id='descend',priority=10,when={enemy_count={eq=0}},['then']={action='change_level'}}}
    check(Schema.validate(p),'change_level is re-admitted as an auto-combat action')
    local bound=basePolicy()
    bound.rules={{id='descend',priority=10,when={always={}},
        ['then']={action='change_level',target='self'}}}
    check(not Schema.validate(bound),'change_level binds no target')
    local permissions=basePolicy()
    permissions.permissions={change_level=true}
    check(not Schema.validate(permissions),'the permissions field is no longer accepted')
end
-- MOV-1: move + destination selector + explicit acceptance conditions --------
do
    local function moveRule(destination)
        local p=basePolicy()
        p.rules={{id='kite',priority=50,when={nearest_enemy_distance={lt=3}},
            ['then']={action='move',target='nearest_hostile',destination=destination}}}
        return p
    end
    local accept={visibility='any',passability='native',hazard='avoid_known',landing='allow_random'}
    check(Schema.validate(moveRule({selector='away',anchor='bound_target',accept=accept})),
        'a plain step with an `away` destination validates (ordinary kiting)')
    check(Schema.validate(moveRule({selector='toward',anchor='bound_target',accept=accept})),
        'a `toward` destination validates')
    check(Schema.validate(moveRule({selector='preferred_distance',anchor='self',distance=4,accept=accept})),
        'a `preferred_distance` destination validates')
    check(Schema.validate(moveRule({selector='position',x=17,y=9,accept=accept})),
        'an explicit out-of-vision position validates')
    check(Schema.validate(moveRule({selector='relative',dx=-1,dy=0,accept=accept})),
        'a relative destination validates')
    -- Every acceptance field is explicit: there is no hidden plugin default.
    check(not Schema.validate(moveRule({selector='away',anchor='bound_target',
        accept={visibility='any',passability='native',hazard='any'}})),
        'a destination missing an accept field is rejected')
    check(not Schema.validate(moveRule({selector='away',anchor='bound_target',
        accept={visibility='any',passability='native',hazard='any',landing='sometimes'}})),
        'an unknown accept value is rejected')
    check(not Schema.validate(moveRule({selector='native_random',anchor='self',accept=accept})),
        'a plain step rejects the talent-only native_random selector')
    check(not Schema.validate(moveRule({selector='position',x=1,accept=accept})),
        'position requires both coordinates')
    local noDest=basePolicy()
    noDest.rules={{id='step',priority=10,when={always={}},['then']={action='move'}}}
    check(not Schema.validate(noDest),'move requires a destination or an explicit direction')
    local dir=basePolicy()
    dir.rules={{id='step',priority=10,when={always={}},['then']={action='move',direction=4}}}
    check(Schema.validate(dir),'move accepts a fixed keypad direction')
    local badDir=basePolicy()
    badDir.rules={{id='step',priority=10,when={always={}},['then']={action='move',direction=5}}}
    check(not Schema.validate(badDir),'direction 5 (wait) is not a movement direction')
    local restDest=basePolicy()
    restDest.rules={{id='camp',priority=10,when={always={}},
        ['then']={action='rest',destination={selector='position',x=1,y=1,accept=accept}}}}
    check(not Schema.validate(restDest),'rest rejects a destination binding')
end
-- MOV-1: ordered target_plan validation -------------------------------------
do
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local p=basePolicy()
    p.rules={{id='door',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
            target_plan={ {request='self'},
                {request='grid',destination={selector='away',anchor='bound_target',accept=accept}} }}}}
    check(Schema.validate(p),'an ordered actor-then-grid target_plan validates')
    local bad=basePolicy()
    bad.rules={{id='door',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
            target_plan={ {request='teleport'} }}}}
    check(not Schema.validate(bad),'an unknown target request is rejected')
    local noPlan=basePolicy()
    noPlan.rules={{id='door',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',target_plan={}}}}
    check(not Schema.validate(noPlan),'an empty target_plan is rejected')
    -- Checklist A (boundary-selfcheck): the plan is caller-supplied, so a sparse
    -- plan must be rejected at ingress rather than measured as a shorter complete
    -- plan (Lua `#` stops at the first hole; `ipairs` terminates there).
    local function planError(p,path)
        local ok,errors=Schema.validate(p)
        if ok then return nil end
        for _,error in ipairs(errors or {}) do if error.path==path then return error.code end end
        return nil
    end
    local holed=basePolicy()
    holed.rules={{id='door',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
            target_plan={[1]={request='self'},[3]={request='grid',
                destination={selector='away',anchor='bound_target',accept=accept}}}}}}
    check(planError(holed,'rules[1].then.target_plan')=='invalid_target_plan',
        'a sparse (holed) target_plan is invalid_target_plan at policy ingress')
    local nonInteger=basePolicy()
    nonInteger.rules={{id='door',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
            target_plan={[1]={request='self'},oops={request='grid'}}}}}
    check(planError(nonInteger,'rules[1].then.target_plan')=='invalid_target_plan',
        'a non-integer target_plan key is invalid_target_plan at policy ingress')
    local beyondEnd=basePolicy()
    beyondEnd.rules={{id='door',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
            target_plan={[1]={request='self'},[1.5]={request='grid'}}}}}
    check(planError(beyondEnd,'rules[1].then.target_plan')=='invalid_target_plan',
        'a fractional target_plan key is invalid_target_plan at policy ingress')
    -- A dense plan still validates (no false positive).
    local dense=basePolicy()
    dense.rules={{id='door',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
            target_plan={ {request='self'},
                {request='grid',destination={selector='away',anchor='bound_target',accept=accept}} }}}}
    check(Schema.validate(dense),'a dense ordered target_plan still validates')
    -- Checklist A: the evaluator's actor step selector reads the same
    -- caller-supplied plan; a sparse plan must not resolve a selector out of a
    -- truncated `ipairs` prefix (it carries no trustworthy binding).
    check(Evaluator.actorStepSelector({target_plan={[1]={request='actor',selector='self'},
        [3]={request='actor',selector='nearest_hostile'}}})==nil,
        'a sparse target_plan resolves no actor step selector')
    check(Evaluator.actorStepSelector({target_plan={{request='actor',selector='nearest_hostile'}}})
        =='nearest_hostile','a dense target_plan still resolves its actor selector')
end
-- S2-R4-01: the agility Vault must NOT be executable. Its first (actor) prompt's
-- target is attacked and may be dazed before the move, so component-free
-- grid-movement admission would let a policy bind that actor prompt to `self`
-- and aim an offensive native action at the player with the effect hidden from
-- the movement-skipping guard. It must be rejected as an unsupported talent.
do
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local p=basePolicy()
    p.rules={{id='vault-self',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_VAULT',target='self',
            destination={selector='position',x=3,y=3,accept=accept},
            target_plan={{request='actor',selector='self'}}}}}
    local ok,errors=Schema.validate(p)
    check(ok==nil,'the agility Vault is not an executable schema talent')
    local code=nil
    for _,error in ipairs(errors or {}) do
        if error.path=='rules[1].then.talent' then code=error.code end
    end
    check(code=='unsupported_talent','a self-bound Vault rule is rejected as unsupported_talent')
    -- The acrobatics Vault (a different, single-prompt pure-movement talent)
    -- stays a valid schema talent.
    local skirmisher=basePolicy()
    skirmisher.rules={{id='svault',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_SKIRMISHER_VAULT',target='self',
            destination={selector='position',x=3,y=3,accept=accept}}}}
    check(Schema.validate(skirmisher),'T_SKIRMISHER_VAULT stays a valid schema talent')
end
do
    -- v1.6: `emergency` is a scheduling label only. It is not an action
    -- allowlist, so any declared action may carry it; the executor guard is the
    -- safety gate for the bound `use_talent`/`attack`.
    local p=basePolicy()
    p.rules={{id='panic-rest',priority=100,emergency=true,when={always={}},
        ['then']={action='rest',max_turns=5}}}
    check(Schema.validate(p),'an emergency rest rule is shape-valid; emergency is a scheduling label')
    local move=basePolicy()
    move.rules={{id='panic-kite',priority=100,emergency=true,when={always={}},
        ['then']={action='move',target='nearest_hostile',
            destination={selector='away',anchor='bound_target',
                accept={visibility='any',passability='native',hazard='any',landing='allow_random'}}}}}
    check(Schema.validate(move),'an emergency move/kite rule is shape-valid (no action allowlist)')
    local attack=basePolicy()
    attack.rules={{id='panic-attack',priority=100,emergency=true,when={always={}},
        ['then']={action='attack',target='nearest_hostile'}}}
    check(Schema.validate(attack),'an emergency attack is shape-valid; the executor guard is the safety gate')
end
-- v1.6 scheduling mode (MFT-REV-01) ------------------------------------------
do
    local p=basePolicy()
    p.mode={on_no_enemy='evaluate_rules',on_low_hp='evaluate_rules'}
    check(Schema.validate(p),'an explicit scheduling mode validates')
    local bad=basePolicy();bad.mode={on_low_hp='assist'}
    check(not Schema.validate(bad),'an unknown low-HP mode is rejected')
    bad=basePolicy();bad.mode={on_no_enemy='wander'}
    check(not Schema.validate(bad),'an unknown no-enemy mode is rejected')
    -- A policy-authored kite executes at low HP under evaluate_rules; the
    -- conservative default keeps the emergency-only layer.
    local kite={id='kite',priority=10,when={always={}},['then']={action='move',
        target='nearest_hostile',destination={selector='away',anchor='bound_target',
            accept={visibility='any',passability='native',hazard='any',landing='allow_random'}}}}
    local explicit=basePolicy()
    explicit.mode={on_low_hp='evaluate_rules'}
    explicit.rules={kite}
    local d=Evaluator.evaluate(explicit,ctx({hp_pct=10,enemy_count=1}))
    check(d.decision=='act' and d.rule=='kite' and d.action=='move',
        'evaluate_rules executes a declared movement rule below min_hp_pct')
    local conservative=basePolicy()
    conservative.safety.flee_below_hp_pct=nil
    conservative.rules={kite}
    local c=Evaluator.evaluate(conservative,ctx({hp_pct=10,enemy_count=1}))
    check(c.decision=='pause' and c.reason=='no_emergency_action',
        'the conservative default stays emergency-only below min_hp_pct')
    local emergency=basePolicy()
    emergency.mode={on_low_hp='emergency_only'}
    emergency.rules={kite,{id='panic-kite',priority=100,emergency=true,when={always={}},
        ['then']=kite['then']}}
    local e=Evaluator.evaluate(emergency,ctx({hp_pct=10,enemy_count=1}))
    check(e.decision=='act' and e.rule=='panic-kite','emergency_only schedules only emergency-labelled rules')
    local paused=basePolicy()
    paused.mode={on_low_hp='pause'}
    paused.safety.flee_below_hp_pct=nil
    paused.rules={kite}
    local pa=Evaluator.evaluate(paused,ctx({hp_pct=10,enemy_count=1}))
    check(pa.decision=='pause' and pa.reason=='below_min_hp_pct','low_hp=pause pauses below min_hp_pct')
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

-- D-1 (P1, round anor-reg-01 live regression): an emergency rule that matched
-- this opportunity but was refused must fall through to the remaining normal
-- rules instead of parking. A pause would freeze the world (full player energy),
-- so a native cooldown would never decay and every restart would repeat the
-- deny -> pause sequence forever.
do
    local policy=basePolicy()
    policy.mode={on_low_hp='emergency_only'}
    policy.rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
        {id='melee',priority=50,when={always={}},
            ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}},
    }
    local denied={heal=true}
    local decision=Evaluator.evaluate(policy,ctx({hp_pct=30,denied=denied}))
    check(decision.decision=='act' and decision.rule=='melee' and decision.fallback==true,
        'a refused emergency action falls through to the next applicable rule (D-1)')
    check(decision.emergency==false and decision.critical==true,
        'a fall-through action stays in the critical layer without being an emergency rule')
    local sawDenied,sawFallback=false,false
    for _,row in ipairs(decision.results) do
        if row.rule=='heal' and row.result=='denied' then sawDenied=true end
        if row.rule=='melee' and row.fallback then sawFallback=true end
    end
    check(sawDenied and sawFallback,'the decision trace records the refusal and the fall-through rule')
    -- When nothing at all is applicable the reason is the typed refusal
    -- (`action_denied`), never `no_emergency_action`.
    local onlyHeal=basePolicy()
    onlyHeal.mode={on_low_hp='emergency_only'}
    onlyHeal.rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
    }
    local stuck=Evaluator.evaluate(onlyHeal,ctx({hp_pct=30,denied={heal=true}}))
    check(stuck.decision=='pause' and stuck.reason=='action_denied' and stuck.rule=='heal',
        'a refused emergency action with no applicable fallback pauses action_denied (D-1)')
    -- An emergency rule that never matched at all keeps the declared reason.
    local unmatched=basePolicy()
    unmatched.mode={on_low_hp='emergency_only'}
    unmatched.rules={
        {id='heal',priority=100,emergency=true,when={hp_pct={lt=5}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
    }
    local none=Evaluator.evaluate(unmatched,ctx({hp_pct=30}))
    check(none.decision=='pause' and none.reason=='no_emergency_action',
        'an emergency layer with nothing matching keeps no_emergency_action')
end

-- D-3: `on_new_enemy` is a validated mode value and the legacy boolean maps.
do
    local p=basePolicy();p.mode={on_new_enemy='continue'}
    check(Schema.validate(p),'on_new_enemy=continue is a valid mode value')
    p.mode={on_new_enemy='resume_continue'}
    check(not Schema.validate(p),'an unknown on_new_enemy mode value is rejected')
    check(Evaluator.newEnemyMode({mode={on_new_enemy='continue'}})=='continue',
        'the explicit mode wins')
    check(Evaluator.newEnemyMode({safety={pause_on_new_enemy=false}})=='continue',
        'the legacy boolean maps false -> continue')
    check(Evaluator.newEnemyMode({safety={pause_on_new_enemy=true}})=='pause',
        'the legacy boolean maps true -> pause')
    check(Evaluator.newEnemyMode({})=='pause','the conservative default is pause')
end

-- BND-REV-01: sparse caller arrays must be rejected typed at every schema
-- ingress (checklist A). The reviewer's production reproduction: a valid rule at
-- index 1 and an INVALID rule at index 3 used to be measured as a complete
-- one-rule policy (`schema_ok=true errors=0 lua_len=1`).
do
    local p=basePolicy()
    p.rules={[1]={id='heal-low',priority=100,
            when={hp_pct={lt=50}},['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
        [3]={id='bad',priority=1,when={always=true},['then']={action='definitely_invalid'}}}
    local ok,errors=Schema.validate(p)
    check(not ok,'a sparse policy.rules (hole at 3) is rejected at ingress')
    check(errors and errors[1] and errors[1].code=='rules_required' and errors[1].cause=='hole',
        'the sparse rules ingress fails typed (rules_required/cause=hole), not silently shorter')
    -- key beyond the dense end is the same family (the tail rule is hidden).
    local p2=basePolicy()
    p2.rules={[1]=p2.rules[1],[4]=p2.rules[2]}
    local ok2,errors2=Schema.validate(p2)
    check(not ok2 and errors2[1].code=='rules_required' and errors2[1].cause=='hole',
        'a key beyond the dense end in policy.rules is rejected at ingress')
    -- a non-integer key likewise.
    local p3=basePolicy(); p3.rules[1.5]=p3.rules[1]
    local ok3,errors3=Schema.validate(p3)
    check(not ok3 and errors3[1].cause=='non_integer_key',
        'a non-integer key in policy.rules is rejected at ingress')
    -- sustains ingress.
    local p4=basePolicy(); p4.sustains={[1]={talent='T_ARCANE_POWER'},[3]={talent='T_HEALING_LIGHT'}}
    local ok4,errors4=Schema.validate(p4)
    check(not ok4 and errors4[1].code=='invalid_sustains' and errors4[1].cause=='hole',
        'a sparse policy.sustains is rejected at ingress')
    -- condition group ingresses.
    local p5=basePolicy(); p5.rules[1].when={all={[1]={hp_pct={lt=50}},[3]={always=true}}}
    local ok5,errors5=Schema.validate(p5)
    check(not ok5 and errors5[1].code=='invalid_all' and errors5[1].cause=='hole',
        'a sparse cond.all group is rejected at ingress')
    local p6=basePolicy(); p6.rules[2].when={any={[1]={hp_pct={lt=50}},[3]={always=true}}}
    local ok6,errors6=Schema.validate(p6)
    check(not ok6 and errors6[1].code=='invalid_any' and errors6[1].cause=='hole',
        'a sparse cond.any group is rejected at ingress')
    -- tie-break ingress.
    local p7=basePolicy(); p7.targeting.tie_break={[1]='distance',[3]='hp'}
    local ok7,errors7=Schema.validate(p7)
    check(not ok7 and errors7[1].code=='invalid_tie_break' and errors7[1].cause=='hole',
        'a sparse policy.targeting.tie_break is rejected at ingress')
end

-- BND-REV-01: the evaluator never measures a sparse caller array as a complete
-- smaller one: a malformed cond.all is UNKNOWN (not FALSE from a truncated
-- prefix), a malformed cond.any cannot satisfy, a sparse policy.rules holds
-- typed, and a safety-classified malformed group fails closed to pause.
do
    check(Evaluator.evalCondition({all={[1]={always=true},[2]={hp_pct={lt=1}}}},{hp_pct=0})==Evaluator.TRUE,
        'a dense group still evaluates normally (sanity)')
    check(Evaluator.evalCondition({all={[1]={always=true},[3]={mystery=true}}},{})==Evaluator.UNKNOWN,
        'a sparse cond.all is UNKNOWN, never a truncated complete group')
    check(Evaluator.evalCondition({any={[1]={hp_pct={lt=1}},[3]={always=true}}},{} )==Evaluator.UNKNOWN,
        'a sparse cond.any is UNKNOWN, never a truncated prefix measured as complete')
    check(Evaluator.isSafety({all={[1]={hp_pct={lt=1}},[3]={always=true}}})==true,
        'a sparse safety condition group fails closed (treated as safety)')
    local sparse=basePolicy()
    sparse.rules={[1]=sparse.rules[1],[3]=sparse.rules[2]}
    local decision=Evaluator.evaluate(sparse,ctx({hp_pct=30}))
    check(decision.decision=='hold' and decision.reason=='invalid_rules',
        'the evaluator fails closed to a typed hold on a sparse policy.rules')
    check(decision.cause=='hole','the typed hold carries the dense cause')
end

print('Auto-combat policy: '..checks..' checks passed')
