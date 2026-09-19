-- R2 (option A): declared interchangeable groups — runtime exactly-one gate.
--
-- The maintainer chose option A for the unsupported-entry audit's R2 item
-- (`tmp/mcp-play-support/unsupported-audit.md`): `T_EARTHEN_MISSILES`
-- (`spells/stone.lua:37-58`) and `T_DWARVEN_HALF_EARTHEN_MISSILES`
-- (`gifts/dwarven-nature.lua:35-50`) have three prompts that are
-- indistinguishable by signature (all three specs are
-- `{type="bolt", range=getTalentRange, talent=t, display=...}`) yet SEMANTICALLY
-- EQUIVALENT: `damage` is computed ONCE and every prompt fires the SAME
-- projectile with the SAME `DamageType.SPLIT_BLEED`
-- (`self:projectile(tg, x, y, DamageType.SPLIT_BLEED, self:spellCrit(damage), nil)`,
-- `spells/stone.lua:40-56`). Answering "missile #2" with "missile #1's" decided
-- coordinate therefore has no observable consequence, so refusing them violates
-- the AGENTS rule that a faithfully executable legal action must not be refused.
--
-- This suite drives the REAL production `Actions.execute` queue (the merged
-- authoritative-prefill path) with a native body that raises the same bolt
-- prompt repeatedly, exactly as the reviewed action does. The mechanism is
-- NARROW and declared (the `group` value is curated data — never an
-- identity/digest/closure gate); every ungrouped pair keeps today's behaviour
-- exactly, and a matched set that crosses groups / matches an ungrouped entry
-- ambiguously / matches a non-member still produces `unexpected_target_request`
-- with expected/observed/matched_indexes.
--
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
local Actions=require 'mod.mcp_bridge.Actions'
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local Factory=require 'mod.auto_combat.MovementAdapterFactory'
local Planner=require 'mod.auto_combat.MovementPlanner'
local Manifest=require 'mod.auto_combat.EffectManifest'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- Controlled seams: the native compatibility gate and the tracker are stubbed
-- exactly as the existing S2 sequence suite does, so the fixture's own
-- `useTalent`/`getTarget` are the only native entrypoints driven.
local realStart,realCheck,realMatches=Tracker.start,Compat.check,Compat.matches
Tracker.start=function(_,_,fn)
    local ok,value=pcall(fn)
    if not ok then error(value,0) end
    return {test=true},value
end
Compat.check=function() return true end
Compat.matches=function() return true end

local meta={protocol_version=4,session_id='s',level_instance_id='l',revision=1}
-- The curated Earthen Missiles equivalence proof: one computed damage value and
-- the same projectile/DamageType for every prompt (spells/stone.lua:40-56).
local PROOF='one computed damage and the same projectile/DamageType.SPLIT_BLEED '
    ..'for every prompt (spells/stone.lua:40-56)'
local BOLT={cursor_type='bolt',nowarning=true}
local GRID_SIG={cursor_type='ball',nowarning=true}

-- A native body that raises `def.prompts` (copies of the reviewed specs) in
-- order and records every answer. Mirrors Earthen Missiles' action shape: the
-- same bolt spec is raised once per missile.
local function scriptedAction(def)
    return function(self)
        local answers={}
        for _,spec in ipairs(def.prompts or {}) do
            local copy={}
            for key,value in pairs(spec) do copy[key]=value end
            local x,y,entity=self:getTarget(copy)
            answers[#answers+1]={x=x,y=y,entity=entity}
            if def.stop_on_cancel and x==nil then return nil end
        end
        if def.on_answer then return def.on_answer(self,answers) end
        for _,answer in ipairs(answers) do if answer.x==nil then return nil end end
        return true
    end
end

local function expandOrFail(template,params)
    local out,err=Factory.expand(template,params)
    if not out then error('expand failed: '..Json.encode(err or {}),2) end
    return out
end

local function planOrFail(attempt,prov,movement,origin)
    local out,err=Planner.planSequence(attempt,prov,movement,origin)
    if not out then error('plan failed: '..Json.encode(err or {}),2) end
    return out
end

local function player(defs,origin)
    local p={x=origin.x,y=origin.y,energy={value=1000},talents={},talents_def={}}
    for id,def in pairs(defs) do
        p.talents[id]=1
        def.id=id
        def.mode=def.mode or 'activated'
        def.action=scriptedAction(def)
        p.talents_def[id]=def
    end
    p.useTalent=function(self,id)
        local def=self.talents_def[id]
        return def.action(self,def)
    end
    setmetatable(p,{__index={getTarget=function() return 99,99,nil end}})
    return p
end

local function runQueue(def,action)
    local p=player({T_SEQ=def},{x=1,y=1})
    local g={player=p,level={map={w=20,h=20}}}
    local command={command_id='c1'}
    local result=Actions.execute(g,action,nil,meta,command)
    if result.sequence_deviation then
        local valid,err=Actions.validateDeviation(result.sequence_deviation)
        assert(valid,'deviation record shape violated: '..tostring(err))
    end
    check(rawget(p,'getTarget')==nil,'the queue wrapper is always removed from the player')
    return result,command,p
end

-- A declared interchangeable group of `n` identical bolt prompts, exactly as the
-- curated descriptor declares it (group + one shared equivalence proof). The
-- closed `delivery`/`landing` values are the fixture's own; the group mechanism
-- is independent of them.
local function groupMovement(n,group)
    local declared={}
    for i=1,n do
        declared[i]={index=i,request='grid',subject='self',value_source='target_plan',
            observed=BOLT,group=group or 'earthen_missiles',equiv=PROOF}
    end
    return expandOrFail('request_then_landing',{request_sequence=declared,
        delivery='step',landing='source_defined',center='self',
        traverses=false,relocates_other=false,range=10})
end

local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
local provider={origin=function() return {x=2,y=2} end,
    anchor=function() return {x=2,y=2} end,
    knowledge=function() return {in_bounds=true,visible=true,passable=true,hazard=false} end}
local function gridPlan(n)
    local plan={}
    for i=1,n do
        plan[i]={request='grid',destination={selector='position',x=2+i,y=2,accept=accept}}
    end
    return {talent='T_EARTHEN_MISSILES',target='self',target_plan=plan}
end

-- 1. The descriptor carries the declared group (arrival order preserved) ------
do
    local movement=groupMovement(3)
    check(movement.request_sequence[1].group=='earthen_missiles'
        and movement.request_sequence[1].equiv==PROOF,
        'the normalised descriptor keeps the declared group and its equivalence proof')
    check(movement.request_sequence[1].group==movement.request_sequence[3].group,
        'every member of the group declares the same group value')
    check(#Factory.groupMembers(movement.request_sequence,2)==3,
        'groupMembers returns all three members for any member index')
    local plan=planOrFail(gridPlan(3),provider,movement,{x=2,y=2})
    check(plan.values[1].group=='earthen_missiles' and plan.values[2].group=='earthen_missiles'
        and plan.values[3].group=='earthen_missiles',
        'each decided value carries the declared group (the executor carrier)')
    check(#plan.steps==3,'the planner lowers the three-entry program into three steps')
end

-- 2. The TL5 three-prompt program settles; answers are the k-th decided values -
do
    local movement=groupMovement(3)
    local plan=planOrFail(gridPlan(3),provider,movement,{x=2,y=2})
    local answers={}
    local def={prompts={{type='bolt',range=10,nowarning=true},
            {type='bolt',range=10,nowarning=true},
            {type='bolt',range=10,nowarning=true}},
        on_answer=function(self,seen) answers=seen;return true end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',sequence=plan.values})
    check(result.ok and result.code=='action_complete',
        'a 3-prompt interchangeable group settles in one submission')
    check(result.sequence_deviation==nil,'an in-group match is never a deviation')
    check(#command.target_sequence==3,'all three observed prompts are recorded')
    check(answers[1].x==3 and answers[2].x==4 and answers[3].x==5,
        'the k-th prompt is answered with the k-th decided value in arrival order')
    check(result.target_sequence~=nil and #result.target_sequence==3,
        'the observed sequence is surfaced on the result for evidence')
end

-- 3. The below-TL5 two-prompt program (the other variant-matrix cell) settles --
do
    local movement=groupMovement(2)
    local plan=planOrFail(gridPlan(2),provider,movement,{x=2,y=2})
    check(plan.values[1].group=='earthen_missiles' and plan.values[2].group=='earthen_missiles',
        'the two-entry program carries the same declared group')
    local answers={}
    local def={prompts={{type='bolt',range=10,nowarning=true},{type='bolt',range=10,nowarning=true}},
        on_answer=function(self,seen) answers=seen;return true end}
    local result=runQueue(def,{type='use_talent',talent_id='T_SEQ',sequence=plan.values})
    check(result.ok,'the below-TL5 two-prompt group settles')
    check(answers[1].x==3 and answers[2].x==4,
        'the two-prompt program answers both prompts with their own decided values')
end

-- 4. A prompt matching NO member of the expected group is a typed deviation ---
do
    local movement=expandOrFail('request_then_landing',{request_sequence={
        {index=1,request='grid',subject='self',value_source='target_plan',observed=BOLT,
            group='earthen_missiles',equiv=PROOF},
        {index=2,request='grid',subject='self',value_source='target_plan',observed=BOLT,
            group='earthen_missiles',equiv=PROOF},
        {index=3,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='beam',nowarning=true}}},
        delivery='step',landing='source_defined',center='self',
        traverses=false,relocates_other=false,range=10})
    local plan=planOrFail(gridPlan(3),provider,movement,{x=2,y=2})
    -- A `cone` prompt matches NO declared entry at all: the expected grouped
    -- position is not satisfied and the matched set is empty.
    local def={prompts={{type='cone',range=10,nowarning=true}},on_answer=function() return true end}
    local result=runQueue(def,{type='use_talent',talent_id='T_SEQ',sequence=plan.values})
    check(not result.ok and result.code=='unexpected_target_request',
        'a prompt matching no member of the expected group is unexpected_target_request')
    local dev=result.sequence_deviation
    check(dev and dev.expected.index==1 and dev.expected.request=='grid'
        and dev.observed.index==1 and dev.observed_shape=='cone'
        and type(dev.matched_indexes)=='table' and #dev.matched_indexes==0,
        'the zero-match deviation carries expected/observed/matched_indexes')
    -- A prompt matching only an entry OUTSIDE the expected group is likewise a
    -- typed deviation (never answered with the grouped lane's value); here the
    -- raised `beam` matches the ungrouped third entry only.
    local defOut={prompts={{type='beam',range=10,nowarning=true}},on_answer=function() return true end}
    local resultOut=runQueue(defOut,{type='use_talent',talent_id='T_SEQ',sequence=plan.values})
    check(not resultOut.ok and resultOut.code=='unexpected_target_request',
        'a prompt matching only an out-of-group entry is unexpected_target_request')
    check(resultOut.sequence_deviation.matched_indexes[1]==3
        and #resultOut.sequence_deviation.matched_indexes==1,
        'the out-of-group deviation reports the outside match index')
end

-- 5. A matched set crossing two declared groups is still a typed deviation ----
-- The two groups carry signatures that OVERLAP without either subsuming the
-- other (each declares a DIFFERENT string discriminator, and a declared string
-- must be present-and-equal), which the build admits across groups. The runtime
-- gate must reject it: the matched set is not confined to the expected group.
do
    local movement=expandOrFail('request_then_landing',{request_sequence={
        {index=1,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='bolt',first_target='friend'},group='group_a',equiv=PROOF},
        {index=2,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='bolt',first_target='friend'},group='group_a',equiv=PROOF},
        {index=3,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='bolt',msg='pick'},group='group_b',equiv=PROOF},
        {index=4,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='bolt',msg='pick'},group='group_b',equiv=PROOF}},
        delivery='step',landing='source_defined',center='self',
        traverses=false,relocates_other=false,range=10})
    local plan=planOrFail(gridPlan(4),provider,movement,{x=2,y=2})
    local def={prompts={{type='bolt',range=10,first_target='friend',msg='pick'}},
        on_answer=function() return true end}
    local result=runQueue(def,{type='use_talent',talent_id='T_SEQ',sequence=plan.values})
    check(not result.ok and result.code=='unexpected_target_request',
        'a matched set crossing two declared groups is unexpected_target_request')
    local dev=result.sequence_deviation
    check(dev and #dev.matched_indexes==4
        and dev.matched_indexes[1]==1 and dev.matched_indexes[4]==4,
        'the crossing-group deviation reports every matched index')
end

-- 6. An ambiguous UNGROUPED match keeps exactly today's behaviour -------------
do
    local def={prompts={{type='bolt',range=10,nowarning=true}},on_answer=function() return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='grid',x=3,y=2,observed=BOLT},
                {kind='grid',request='grid',x=4,y=2,observed=BOLT}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'an ambiguous UNGROUPED two-match set is still unexpected_target_request')
    check(result.sequence_deviation and #result.sequence_deviation.matched_indexes==2,
        'the ungrouped ambiguity reports both matched indexes')
end

-- 7. A prompt matching only a LATER position never satisfies a grouped lane ---
do
    local movement=expandOrFail('request_then_landing',{request_sequence={
        {index=1,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='bolt',nolock=true},group='pair',equiv=PROOF},
        {index=2,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='bolt',nolock=true},group='pair',equiv=PROOF},
        {index=3,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='ball',nowarning=true},optional=true}},
        delivery='step',landing='source_defined',center='self',
        traverses=false,relocates_other=false,range=10})
    local plan=planOrFail(gridPlan(3),provider,movement,{x=2,y=2})
    local def={prompts={{type='ball',range=10,nowarning=true}},on_answer=function() return true end}
    local result=runQueue(def,{type='use_talent',talent_id='T_SEQ',sequence=plan.values})
    check(not result.ok and result.code=='unexpected_target_request',
        'a prompt matching only a later position still deviates for a grouped lane')
    check(result.sequence_deviation.matched_indexes[1]==3,
        'the deviation reports the out-of-position match index')
end

-- 8. The internal carrier accepts the closed `group` value, rejects malformed --
do
    local ok=Actions.validate({type='use_talent',talent_id='T_A',sequence={
        {kind='grid',x=3,y=4,observed=GRID_SIG,group=1},
        {kind='grid',x=3,y=5,observed=GRID_SIG,group=1}}})
    check(ok~=nil and ok.sequence[1].group==1,
        'a directly submitted carrier keeps its declared group')
    check(Actions.validate({type='use_talent',talent_id='T_A',sequence={
        {kind='grid',x=3,y=4,observed=GRID_SIG,group='not closed'}}})==nil,
        'a malformed carrier group value is invalid_sequence')
    -- The group is never inferred by equality: an ungrouped carrier with two
    -- identical signatures stays admitted (no carrier-level pairwise gate), and
    -- the RUNTIME gate above refuses the ambiguous match (case 6).
    local ungrouped=Actions.validate({type='use_talent',talent_id='T_A',sequence={
        {kind='grid',x=3,y=4,observed=GRID_SIG},
        {kind='grid',x=3,y=5,observed=GRID_SIG}}})
    check(ungrouped~=nil and ungrouped.sequence[1].group==nil,
        'carrier entries without a declared group never gain one by inference')
end

-- 9. STOP-condition evidence (item 7 of the brief). Admitting Earthen Missiles
-- as a `movement` entry would require the descriptor vocabulary to express "fire
-- N projectiles at N chosen grids WITHOUT moving the player" and the guard to
-- see the declared damage. Neither holds on this branch, so the brief's STOP
-- clause applies: the talents stay UNSUPPORTED with an honest typed reason and
-- this suite records the exact, runnable gap instead of forcing a template.
do
    -- (a) The closed `delivery` vocabulary has no stationary-project member:
    -- every admitted value denotes the MOVER relocating (step/line_move/leap/
    -- teleport/scene_change). `landing`/`center` likewise describe a mover
    -- landing, and `request_then_landing` requires both.
    check(Factory.DELIVERIES.project~=true and Factory.DELIVERIES.projectile~=true
        and Factory.DELIVERIES.cast~=true and Factory.DELIVERIES.stationary~=true,
        'the closed delivery vocabulary has no stationary-project member')
    check(Factory.DELIVERIES.step==true and Factory.DELIVERIES.line_move==true
        and Factory.DELIVERIES.leap==true and Factory.DELIVERIES.teleport==true
        and Factory.DELIVERIES.scene_change==true,
        'every admitted delivery value denotes a mover relocation')
    check(Factory.CENTERS.requested_grid==true and Factory.LANDINGS.exact==true
        and Factory.LANDINGS.source_defined==true,
        'center/landing are mover-landing concepts only')
    -- (b) The only template with no fixed movement invariant is
    -- `request_then_landing`, yet it still REQUIRES delivery/landing/center. The
    -- closest available value (`step`) would assert the caster steps, which is
    -- false for a projectile-only action — i.e. the vocabulary cannot express it
    -- honestly.
    local spec=Factory.TEMPLATES.request_then_landing
    check(spec.fixed and next(spec.fixed)==nil,
        'request_then_landing fixes no movement invariant')
    check(spec.required.delivery==true and spec.required.landing==true
        and spec.required.center==true,
        'request_then_landing still REQUIRES delivery/landing/center (mover concepts)')
    local movement,err=Factory.expand('request_then_landing',{request_sequence={
        {index=1,request='grid',subject='self',value_source='target_plan',
            observed=BOLT,group=1,equiv=PROOF},
        {index=2,request='grid',subject='self',value_source='target_plan',
            observed=BOLT,group=1,equiv=PROOF}},
        delivery='step',landing='source_defined',center='self',
        traverses=false,relocates_other=false,range=10})
    -- The group mechanism itself expands; the STOP is about the MOVEMENT
    -- semantics being false, not about the group declaration.
    check(movement~=nil and movement.delivery=='step' and movement.center=='self',
        'the group declaration expands, but only under a mover delivery value')
    check(movement.landing=='source_defined',
        'the landing class is a mover-landing annotation')
    -- (c) The guard would skip a movement-kind entry unconditionally, so declared
    -- damage components would be invisible on this branch; the mixed-composition
    -- machinery (S3 `guardMixed`/`actual_landing`) is not present here.
    local guardSource=io.open(root..'/overload/mod/auto_combat/AutoCombatGuard.lua'):read('*a')
    check(guardSource:find("if entry.kind=='movement' then return nil end",1,true)~=nil,
        'the guard skips every movement-kind entry (declared damage would be invisible)')
    check(guardSource:find('guardMixed',1,true)==nil
        and guardSource:find('actual_landing',1,true)==nil,
        'the S3 mixed movement/effect composition guard is not on this branch')
    -- (d) Both talents therefore stay UNSUPPORTED, with an honest typed reason
    -- naming the descriptor gap (not the now-solved signature ambiguity).
    for _,talent in ipairs{'T_EARTHEN_MISSILES','T_DWARVEN_HALF_EARTHEN_MISSILES'} do
        check(Manifest.entry(talent)==nil,
            talent..' stays unexecutable until the descriptor gap is closed')
        local row
        for _,candidate in ipairs(Manifest.UNSUPPORTED) do
            if candidate.talent==talent then row=candidate end
        end
        check(row~=nil,talent..' keeps a structured unsupported row')
        check(row.missing=='stationary_project_delivery',
            talent..' carries the honest stationary-project typed reason')
        check(row.reason:find('spells/stone.lua:40-56',1,true)
            or row.reason:find('gifts/dwarven-nature.lua:35-50',1,true),
            talent..' reason cites the reviewed source')
    end
end

Tracker.start,Compat.check,Compat.matches=realStart,realCheck,realMatches

print('Interchangeable groups: '..checks..' checks passed')
