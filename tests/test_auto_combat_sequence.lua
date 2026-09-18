-- S2: ordered prompt-response queue (`request_sequence`) production tests.
--
-- These drive the real `Actions.execute` queue wrapper (the merged
-- authoritative-prefill path) rather than a fake executor, so the observed
-- answers, the recorded `target_sequence`, the per-request native guard and every
-- typed deviation are the production behaviours. The native compatibility and
-- tracker seams are replaced with the same controlled doubles the existing
-- `tests/test_talent_query.lua` prefill tests use.
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
local AutoCombat=require 'mod.auto_combat.AutoCombat'
local Runtime=require 'mod.mcp_bridge.Runtime'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- Controlled seams: the native compatibility gate is stubbed exactly as the
-- existing prefill tests do; the tracker runs synchronously without a native
-- useTalent seam (the fixture's own `useTalent` is called directly).
local realStart,realCheck,realMatches=Tracker.start,Compat.check,Compat.matches
Tracker.start=function(_,_,fn)
    local ok,value=pcall(fn)
    if not ok then error(value,0) end
    return {test=true},value
end
Compat.check=function() return true end
Compat.matches=function() return true end

local meta={protocol_version=4,session_id='s',level_instance_id='l',revision=1}

-- A fixture player at (1,1) whose `useTalent` raises exactly the prompts the
-- scenario declares. `def.prompts` is a list of specs; the action calls
-- `getTarget` for each and records every answer. `def.on_answer` receives the
-- answers so a scenario can assert or move the player.
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
    -- The real engine `Player:getTarget` is the seam the executor wrapper
    -- replaces. It lives on the metatable (the production prefill tests use the
    -- same shape) so `rawget(p,'getTarget')` is nil and the wrapper-removal
    -- assertion is meaningful; returning a fixed sentinel proves the queue
    -- answered instead of the native UI.
    setmetatable(p,{__index={getTarget=function() return 99,99,nil end}})
    return p
end
function scriptedAction(def)
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
        -- A native action that "succeeds" only when every prompt was answered.
        for _,answer in ipairs(answers) do if answer.x==nil then return nil end end
        return true
    end
end

-- 1. Descriptor validation: the closed `request_sequence` record --------------
do
    local function seq(entries,extra)
        local params={request_sequence=entries,delivery='teleport',landing='random',
            center='self',traverses=false,relocates_other=false}
        for key,value in pairs(extra or {}) do params[key]=value end
        return Factory.expand('request_then_landing',params)
    end
    local valid=assert(seq({{index=1,request='actor',subject='self'},
        {index=2,request='grid',subject='self',value_source='target_plan',
            landing_from='envelope',optional=true}}))
    check(valid.target_requests[1]=='actor' and valid.target_requests[2]=='grid',
        'a valid sequence derives target_requests from the declared kinds')
    check(valid.request_sequence[2].value_source=='target_plan'
        and valid.request_sequence[2].optional==true,
        'the normalised sequence keeps value_source/optional')

    local function invalid(entries,detail)
        local out,err=seq(entries)
        return out==nil and err.reason=='movement_adapter_invalid' and err.detail==detail
    end
    check(invalid({{index=2,request='actor',subject='self'}},'request_index_mismatch'),
        'an explicit index that does not match the array position is rejected')
    check(invalid({{index=1,request='actor',subject='self'},
        {index=2,request='grid',subject='self',optional=true},
        {index=3,request='grid',subject='self'}},'optional_not_trailing'),
        'a non-trailing optional entry is rejected')
    check(invalid({{index=1,request='actor',subject='ghost'}},'bad_subject'),
        'an unknown subject binding is rejected')
    check(invalid({{index=1,request='actor',subject='self',value_source='ghost'}},
        'bad_value_source'),'an unknown value_source is rejected')
    check(invalid({{index=1,request='ghost',subject='self'}},'bad_request_kind'),
        'an unknown request kind is rejected')
    check(invalid({{index=1,request='actor',subject='self',landing_from='exact'}},
        'bad_landing_from'),"a landing_from other than 'envelope' is rejected")
    check(invalid({{index=1,request='actor',subject='self',bogus=1}},'unknown_request_key'),
        'an unknown entry key is rejected')
    check(invalid({{index=1,request='actor',subject='self',optional='yes'}},'bad_optional'),
        'a non-boolean optional is rejected')
    -- A hole in the array is `request_sequence_not_array` (the dense-array rule).
    local holed={[1]={index=1,request='actor',subject='self'},
        [3]={index=3,request='grid',subject='self'}}
    local out,err=seq(holed)
    check(out==nil and err.detail=='request_sequence_not_array','a hole in the sequence is rejected')
    -- target_requests disagreement (length and kind) is invalid.
    local mismatch,merr=seq({{index=1,request='actor',subject='self'}},
        {target_requests={'grid'}})
    check(mismatch==nil and merr.detail=='request_sequence_kind_mismatch',
        'a target_requests kind disagreement is rejected')
    local length,lengErr=seq({{index=1,request='actor',subject='self'}},
        {target_requests={'actor','grid'}})
    check(length==nil and lengErr.detail=='request_sequence_length_mismatch',
        'a target_requests length disagreement is rejected')
    -- A template with a sequence but no curated target_requests derives the list.
    check(valid.target_requests~=nil and #valid.target_requests==2,
        'the capability list is derived when omitted')
end

-- 2. Planner lowering: one plan per declared entry, in order ------------------
do
    local movement=assert(Factory.expand('request_then_landing',{
        request_sequence={{index=1,request='actor',subject='self'},
            {index=2,request='grid',subject='self',value_source='target_plan',
                landing_from='envelope'}},
        delivery='teleport',landing='random',center='requested_grid',
        traverses=false,relocates_other=false,radius=1,min_radius=0,range={getter='getRange'}}))
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local provider={origin=function() return {x=2,y=2} end,
        anchor=function(name) return {x=2,y=2} end,
        knowledge=function() return {in_bounds=true,visible=true,passable=true,hazard=false} end}
    local plan=assert(Planner.planSequence({talent='T_PHASE_DOOR',target='self',
        bound_target=nil,target_plan={{request='actor',selector='self'},
            {request='grid',destination={selector='position',x=5,y=2,accept=accept}}}},
        provider,movement,{x=2,y=2}))
    check(plan.kind=='sequence' and #plan.steps==2,'the planner lowers N entries into N steps')
    check(plan.steps[1].kind=='actor' and plan.steps[2].kind=='grid',
        'the steps are in declared order and of the declared kinds')
    check(plan.values[1].kind=='self' and plan.values[1].request=='actor',
        'the actor entry carries the caster/actor decided value')
    check(plan.values[2].kind=='grid' and plan.values[2].x==5 and plan.values[2].y==2,
        'the grid entry carries its own distinct decided coordinate')
    check(plan.annotation.requests[1]=='actor' and plan.annotation.requests[2]=='grid',
        'the landing annotation reports the declared request kinds')
    check(plan.annotation.landing.kind=='random',
        'a random landing is annotated (not refused) for the policy to decide')
    -- A reversed plan is a length/kind mismatch, not silently reordered.
    local reversed,reversedErr=Planner.planSequence({talent='T_PHASE_DOOR',target='self',
        target_plan={{request='grid',destination={selector='position',x=5,y=2,accept=accept}},
            {request='actor',selector='self'}}},
        provider,movement,{x=2,y=2})
    check(reversed==nil and reversedErr.reason=='target_plan_mismatch',
        'a reversed ordered plan is a typed mismatch')
    -- An un-upgraded multi-prompt adapter keeps the typed capability pause.
    local plain=Planner.plan({action='use_talent',talent='T_X',target='self',
        target_plan={{request='actor',selector='self'},
            {request='grid',destination={selector='position',x=5,y=2,accept=accept}}}},
        provider,{target_requests={'actor','grid'},landing='random'})
    check(plain==nil,'an un-upgraded multi-prompt plan is not executed')
    -- A subject='self' entry with a hostile binding is the S4 capability gap,
    -- never a strategy refusal of the policy.
    local other,otherErr=Planner.planSequence({talent='T_PHASE_DOOR',target='nearest_hostile',
        bound_target='enemy-1',target_plan={{request='actor',selector='nearest_hostile'},
            {request='grid',destination={selector='position',x=5,y=2,accept=accept}}}},
        provider,movement,{x=2,y=2})
    check(other==nil and otherErr.reason=='unsupported_movement_variant'
        and otherErr.missing=='moving_or_swapping_another_actor',
        'a self-subject program bound to another actor is the typed S4 gap')
    -- S2-REV-04: `none` is not a native prompt, so a direct planner call with a
    -- `none` program entry fails closed instead of lowering an entry the
    -- executor would reject (the factory already rejects it at declaration).
    local noneEntry,noneEntryErr=Planner.planSequence({talent='T_X',target='self',
        target_plan={{request='none'}}},
        provider,{request_sequence={{index=1,request='none',subject='self'}},
            landing='random'},{x=2,y=2})
    check(noneEntry==nil and noneEntryErr.reason=='movement_adapter_invalid'
        and noneEntryErr.detail=='bad_request_kind',
        'a none program entry is movement_adapter_invalid, not an executable plan')
end

-- 3. Executor queue: in-order answers, distinct values, recorded sequence -----
local function runQueue(def,action,target)
    local p=player({T_SEQ=def},{x=1,y=1})
    local g={player=p,level={map={w=20,h=20}}}
    local command={command_id='c1'}
    local result=Actions.execute(g,action,target,meta,command)
    check(rawget(p,'getTarget')==nil,'the queue wrapper is always removed from the player')
    return result,command,p
end

do
    local seen={}
    local def={prompts={{type='hit',range=10,nowarning=true},
            {type='ball',range=14,radius=1,nowarning=true}},
        on_answer=function(self,answers)
            seen=answers
            return true
        end}
    local result,command,p=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor'},{kind='grid',request='grid',x=5,y=3}}})
    check(result.ok,'the two-prompt queue settles in one submission')
    check(seen[1].x==1 and seen[1].y==1 and seen[1].entity==p,
        'the first request is answered with the caster cell and entity')
    check(seen[2].x==5 and seen[2].y==3 and seen[2].entity==nil,
        'the second request is answered with its own distinct decided coordinate')
    check(#command.target_sequence==2,'one bounded target_sequence entry per observed request is recorded')
    check(command.target_geometry~=nil and command.target_geometry.shape=='hit',
        'target_geometry keeps its meaning (the first observed native request)')
    check(result.target_sequence~=nil and #result.target_sequence==2,
        'the observed sequence is surfaced on the result for evidence')
end

-- 3b. A single-entry ordered program (Phase Door TL4 actor-only, subject self)
-- is driven by the queue too: the single-target lowering cannot express a
-- self-subject actor prompt without a bound target.
do
    local seen={}
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function(self,answers) seen=answers;return true end}
    local result,command,player=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor'}}},nil)
    check(result.ok,'an N=1 self-subject actor program executes through the queue')
    check(seen[1] and seen[1].x==1 and seen[1].y==1 and seen[1].entity==player,
        'the single actor prompt is answered with the caster cell and entity')
    check(#command.target_sequence==1,'the single observed request is recorded')
end

-- 3c. A grid entry with `value_source='subject'` answers from the subject's
-- cell (the declared source is honoured, never inferred from the cursor).
do
    local movement=assert(Factory.expand('request_then_landing',{
        request_sequence={{index=1,request='grid',subject='self',value_source='subject',
            landing_from='envelope'}},
        delivery='teleport',landing='random',center='requested_grid',traverses=false,
        relocates_other=false,radius=1,min_radius=0,range=10}))
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local provider={origin=function() return {x=2,y=2} end,
        anchor=function() return {x=2,y=2} end,
        knowledge=function() return {in_bounds=true,visible=true,passable=true,hazard=false} end}
    local plan=assert(Planner.planSequence({talent='T_X',target='self',
        target_plan={{request='grid',destination={selector='position',x=6,y=6,accept=accept}}}},
        provider,movement,{x=2,y=2}))
    check(plan.values[1].kind=='grid' and plan.values[1].x==2 and plan.values[1].y==2,
        'a subject-source grid entry answers from the subject cell, not the policy plan')
end

-- 4. Per-request native guard: a value legal for one prompt is refused for
-- another (the actor prompt carries a small range, the grid prompt a large one).
do
    local seen={}
    local def={prompts={{type='hit',range=2,nowarning=true},
            {type='ball',range=10,radius=1,nowarning=true}},
        record=seen,
        -- The native action returns nil once a prompt was cancelled (the native
        -- `if not x then return nil end` shape).
        on_answer=function(self,answers)
            for i,a in ipairs(answers) do seen[i]=a end
            for _,a in ipairs(answers) do if a.x==nil then return nil end end
            return true
        end}
    -- The bound actor sits 5 tiles away: legal for the grid prompt's range 10,
    -- out of range for the actor prompt's range 2.
    local actor={x=6,y=1}
    local result,command,player=runQueue(def,{type='use_talent',talent_id='T_SEQ',
        sequence={{kind='actor',request='actor',target_id='a1'},{kind='grid',request='grid',x=6,y=1}}},
        actor)
    check(not result.ok and result.code=='target_out_of_range',
        'the native range guard is evaluated for the request own spec')
    check(command.target_cancelled=='target_out_of_range',
        'the refusal is the existing typed native target cancel')
    check(seen[1] and seen[1].x==nil,
        'the out-of-range actor value is answered as a native cancel, never bypassed')
end

-- 5. Missing trailing optional is a settled native outcome reported reduced ---
do
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return true end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor'},
                {kind='grid',request='grid',x=5,y=3,optional=true}}})
    check(result.ok and result.reduced==true,
        'a missing trailing optional entry is a settled native outcome with reduced=true')
    check(result.reduced_reason=='trailing_optional_not_raised',
        'the reduced outcome carries its reason')
    check(result.sequence_deviation==nil,'a missing trailing optional is not an error')
end

-- 6. Missing non-optional prompt pauses with unexpected_target_request ---------
do
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return true end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor'},{kind='grid',request='grid',x=5,y=3}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a missing non-optional prompt is the typed unexpected_target_request')
    local deviation=result.sequence_deviation
    check(deviation and deviation.expected.index==2 and deviation.expected.request=='grid'
        and deviation.observed.index==2 and deviation.observed.request==nil
        and deviation.skippable==false,
        'the deviation carries expected/observed index, request and skippable=false')
end

-- 7. Extra prompt (sequence exhausted) pauses typed ---------------------------
do
    local def={prompts={{type='hit',range=10,nowarning=true},
            {type='ball',range=14,radius=1,nowarning=true},
            {type='ball',range=14,radius=1,nowarning=true}},
        on_answer=function() return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor'},{kind='grid',request='grid',x=5,y=3}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a third prompt past the declared sequence is unexpected')
    check(result.sequence_deviation.exhausted==true
        and result.sequence_deviation.observed.index==3,
        'an extra prompt reports the exhausted sequence and observed index 3')
    -- S2-REV-01: the extra prompt's OBSERVED shape is classified and reported,
    -- not a synthetic placeholder.
    check(result.sequence_deviation.observed.request=='grid',
        'the extra prompt reports the observed actor/grid kind')
end

-- 8. Wrong-kind decided value pauses typed (never a wrong answer) -------------
do
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='actor',x=5,y=3}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a decided value whose kind cannot answer the declared prompt is unexpected')
    check(result.sequence_deviation.expected.request=='actor'
        and result.sequence_deviation.observed.request=='grid',
        'the wrong-kind deviation reports expected/observed kinds')
end

-- 9. Unevaluable value pauses with movement_request_value_unknown -------------

-- 9b. S2-REV-01: a reordered NATIVE flow. The declared program is actor-then-
-- grid, but the native body raises a grid-shaped prompt (ball) first and an
-- actor-shaped prompt (hit) second. Every observed prompt is classified from
-- its cursor spec and matched against the declared entry at that index, so the
-- reordered flow is `unexpected_target_request` (never `action_complete`) and
-- the k-th declared value is never blindly answered to the wrong prompt.
do
    local seen={}
    local def={prompts={{type='ball',range=14,radius=1,nowarning=true},
            {type='hit',range=10,nowarning=true}},
        on_answer=function(self,answers)
            seen=answers
            -- The native body completes with whatever the player answered.
            return true
        end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor'},{kind='grid',request='grid',x=5,y=3}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a reordered native flow is the typed unexpected_target_request, not action_complete')
    local deviation=result.sequence_deviation
    check(deviation and deviation.expected.index==1 and deviation.expected.request=='actor'
        and deviation.observed.index==1 and deviation.observed.request=='grid'
        and deviation.skippable==false,
        'the reorder deviation reports the declared actor entry vs the observed grid prompt')
    -- The queue never answered: both prompts were handed to the real native
    -- target request (the metatable seam), so the declared self/grid values are
    -- absent from the native flow and no wrong target was supplied.
    check(seen[1] and seen[1].x==99 and seen[1].y==99 and seen[1].entity==nil,
        'the first (grid-shaped) prompt was handed back to the player, unanswered by the queue')
    check(seen[2] and seen[2].x==99 and seen[2].entity==nil,
        'the second (actor-shaped) prompt was handed back to the player as well')
    check(command.target_sequence and #command.target_sequence==2,
        'both observed prompts are still recorded for evidence')
end

-- 9c. A native cursor spec that cannot be classified unambiguously is never
-- answered blindly: it is a typed deviation with the live interaction handed
-- back (the declared kind stays curated; the cursor type is only a guard).
do
    local def={prompts={{type='exotic_cursor_shape',range=10,nowarning=true}},
        on_answer=function() return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor'}}})
    check(not result.ok and result.code=='movement_request_kind_unknown',
        'an unclassifiable native request shape is a typed deviation, never a blind answer')
    local deviation=result.sequence_deviation
    check(deviation and deviation.expected.request=='actor'
        and deviation.observed_shape=='exotic_cursor_shape' and deviation.skippable==false,
        'the kind-unknown deviation reports the observed native shape')
end
do
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return true end}
    -- An actor-kind value with no resolvable bound actor (the target argument is
    -- nil) is the plugin's own uncomputability boundary.
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='actor',request='actor',target_id='a1'}}})
    check(not result.ok and result.code=='movement_request_value_unknown',
        'an unevaluable decided value is the typed movement_request_value_unknown')
    check(result.sequence_deviation.dependency=='bound_actor'
        and result.sequence_deviation.index==1,
        'the value-unknown deviation carries the index and dependency')
end

-- 10. Validation: the internal sequence field is closed ----------------------
do
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='ghost'}}}),'an unknown sequence kind is invalid_sequence')
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='grid'}}}),'a grid sequence entry needs a coordinate')
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='self',bogus=1}}}),'an unknown sequence field is rejected')
    -- S2-REV-04: `none` is not a native prompt; it cannot form an executable
    -- ordered program (the factory rejects it at declaration time too).
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='self',request='none'}}}),
        'a none request is not a sequence prompt (invalid_sequence)')
    local normalized=Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='self'},{kind='grid',x=3,y=4}}})
    check(normalized and normalized.authoritative_target==true,
        'a valid sequence implies the authoritative wrapper')
    check(Actions.fingerprint({type='use_talent',talent_id='T_A',sequence={{kind='grid',x=3,y=4}}},1)
        ~=Actions.fingerprint({type='use_talent',talent_id='T_A',sequence={{kind='grid',x=3,y=5}}},1),
        'the sequence participates in command dedup')
end

-- 11. Controller: a queue deviation pauses with the typed reason, no resubmit --
do
    local policy={schema='tome-auto-combat/v1',id='p1',name='p1',
        limits={max_actions_per_tick=1},safety={min_hp_pct=35},
        targeting={default='self'},
        rules={{id='door',priority=10,when={always={}},
            ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self'}}}}
    local requests=0
    local host={phase=function() return 'ready' end,
        opportunity_id=function() return 1 end,
        snapshot=function() return {hp_pct=80,enemy_count=1,binding_selector='self'} end,
        enemy_ids=function() return {} end,
        notify=function() end,
        plan=function() return {plan={kind='sequence',values={{kind='self',request='actor'}}}} end,
        request=function()
            requests=requests+1
            return {status='uncertain',code='unexpected_target_request',
                sequence_deviation={reason='unexpected_target_request',
                    expected={index=1,request='actor'},observed={index=1,request='grid'},
                    skippable=false}}
        end}
    local c=AutoCombat.new(policy,host,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='paused' and step.reason=='unexpected_target_request',
        'a queue deviation pauses the controller with the typed reason')
    check(requests==1 and c.attempts==0,
        'a queue deviation is never resubmitted and does not consume the action budget')
    -- The typed deviation reaches the bounded decision ring with its detail.
    local found
    for _,event in ipairs(c:recentDecisions(4)) do
        if event.kind=='paused' and event.reason=='unexpected_target_request' then found=event end
    end
    check(found and found.detail and found.detail.expected.index==1
        and found.detail.observed.request=='grid' and found.detail.skippable==false,
        'the deviation detail reaches the bounded decision ring')
end

Tracker.start,Compat.check,Compat.matches=realStart,realCheck,realMatches

-- 12. Policy validation: the ordered plan validates against the declared
-- sequence; a reversed plan is the existing target_plan_mismatch.
do
    local Schema=require 'mod.auto_combat.PolicySchema'
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local function doorPolicy(plan)
        return {schema='tome-auto-combat/v1',id='pd',name='pd',
            limits={max_actions_per_tick=1},safety={min_hp_pct=35},
            targeting={default='self'},
            rules={{id='door',priority=1,when={enemy_count={ge=1}},
                ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
                    target_plan=plan}}}}
    end
    local ordered=doorPolicy({{request='actor',selector='self'},
        {request='grid',destination={selector='position',x=4,y=4,accept=accept}}})
    check(Schema.validate(ordered),'the ordered Phase Door plan is schema-valid')
    check(Manifest.verify(ordered),'the ordered plan matches the declared actor,grid sequence')
    local reversed=doorPolicy({{request='grid',destination={selector='position',x=4,y=4,accept=accept}},
        {request='actor',selector='self'}})
    local ok,errors=Manifest.verify(reversed)
    local mismatch=false
    for _,error in ipairs(errors or {}) do
        if error.code=='target_plan_mismatch' then mismatch=true end
    end
    check(ok==nil and mismatch,'a reversed plan is the existing target_plan_mismatch')
end

-- 13. Dry run: read-only, non-executing, announced as a sequence.
do
    local Service=require 'mod.auto_combat.AutoCombatService'
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local executed=false
    local host={phase=function() return 'ready' end,
        opportunity_id=function() return 1 end,
        snapshot=function(selector) return {hp_pct=80,enemy_count=1,binding_selector=selector} end,
        enemy_ids=function() return {} end,
        notify=function() end,
        plan=function(attempt)
            return {plan={kind='sequence',annotation={requests={'actor','grid'},
                landing={kind='random',center={x=4,y=4},radius=1}}}}
        end,
        request=function() executed=true;return {status='ok'} end}
    local policy={schema='tome-auto-combat/v1',id='pd',name='pd',
        limits={max_actions_per_tick=1},safety={min_hp_pct=35},targeting={default='self'},
        rules={{id='door',priority=1,when={enemy_count={ge=1}},
            ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
                target_plan={{request='actor',selector='self'},
                    {request='grid',destination={selector='position',x=4,y=4,accept=accept}}}}}}}
    local dry=Service.handle(Service.new{dry_run_host_factory=function() return host end},
        'dry_run',{policy=policy})
    check(dry.decision=='act' and dry.executed==false and dry.side_effects=='none',
        'the ordered queue dry run classifies it as executable and executes nothing')
    check(dry.movement and dry.movement.annotation.requests[1]=='actor'
        and dry.movement.annotation.requests[2]=='grid',
        'the dry-run movement annotation carries the declared request kinds')
    check(dry.movement.annotation.landing.kind=='random',
        'the landing stays a random annotation, not an execution refusal')
    check(executed==false,'dry run never submits a native action')
end

-- 14. Planning never submits an action (design §9.1 test 11).
do
    local Planner=require 'mod.auto_combat.MovementPlanner'
    local executed=false
    local movement=assert(Factory.expand('request_then_landing',{
        request_sequence={{index=1,request='actor',subject='self'},
            {index=2,request='grid',subject='self',value_source='target_plan',landing_from='envelope'}},
        delivery='teleport',landing='random',center='requested_grid',traverses=false,
        relocates_other=false,radius=1,min_radius=0,range=10}))
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local provider={origin=function() return {x=2,y=2} end,
        anchor=function() return {x=2,y=2} end,
        useTalent=function() executed=true end,
        teleportRandom=function() executed=true end,
        knowledge=function() return {in_bounds=true,visible=true,passable=true,hazard=false} end}
    local plan=Planner.planSequence({talent='T_X',target='self',
        target_plan={{request='actor',selector='self'},
            {request='grid',destination={selector='position',x=5,y=2,accept=accept}}}},
        provider,movement,{x=2,y=2})
    check(plan~=nil and executed==false,
        'planning a sequence never calls useTalent/teleportRandom')
end

print('Auto-combat ordered sequence: '..checks..' checks passed')
