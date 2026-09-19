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
-- S2 rev3 curated observed signatures for the fixtures: the actor prompt is the
-- `hit` shape, the landing prompt the `ball` shape (the reviewed Phase Door
-- specs). Dynamic numerics are never signature fields.
local ACTOR_SIG={cursor_type='hit',nowarning=true}
local GRID_SIG={cursor_type='ball',nowarning=true}

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
    local valid=assert(seq({{index=1,request='actor',subject='self',observed=ACTOR_SIG},
        {index=2,request='grid',subject='self',value_source='target_plan',
            landing_from='envelope',optional=true,observed=GRID_SIG}}))
    check(valid.target_requests[1]=='actor' and valid.target_requests[2]=='grid',
        'a valid sequence derives target_requests from the declared kinds')
    check(valid.request_sequence[2].value_source=='target_plan'
        and valid.request_sequence[2].optional==true,
        'the normalised sequence keeps value_source/optional')

    local function invalid(entries,detail)
        local out,err=seq(entries)
        return out==nil and err.reason=='movement_adapter_invalid' and err.detail==detail
    end
    check(invalid({{index=2,request='actor',subject='self',observed=ACTOR_SIG}},'request_index_mismatch'),
        'an explicit index that does not match the array position is rejected')
    check(invalid({{index=1,request='actor',subject='self',observed=ACTOR_SIG},
        {index=2,request='grid',subject='self',optional=true,observed=GRID_SIG},
        {index=3,request='grid',subject='self',observed=GRID_SIG}},'optional_not_trailing'),
        'a non-trailing optional entry is rejected')
    check(invalid({{index=1,request='actor',subject='ghost',observed=ACTOR_SIG}},'bad_subject'),
        'an unknown subject binding is rejected')
    check(invalid({{index=1,request='actor',subject='self',value_source='ghost',observed=ACTOR_SIG}},
        'bad_value_source'),'an unknown value_source is rejected')
    check(invalid({{index=1,request='ghost',subject='self',observed=ACTOR_SIG}},'bad_request_kind'),
        'an unknown request kind is rejected')
    check(invalid({{index=1,request='actor',subject='self',landing_from='exact',observed=ACTOR_SIG}},
        'bad_landing_from'),"a landing_from other than 'envelope' is rejected")
    check(invalid({{index=1,request='actor',subject='self',bogus=1,observed=ACTOR_SIG}},'unknown_request_key'),
        'an unknown entry key is rejected')
    check(invalid({{index=1,request='actor',subject='self',optional='yes',observed=ACTOR_SIG}},'bad_optional'),
        'a non-boolean optional is rejected')
    -- S2 rev3: the observed signature is required and closed-validated.
    check(invalid({{index=1,request='actor',subject='self'}},'bad_observed_signature'),
        'a sequence entry without a curated observed signature is rejected')
    check(invalid({{index=1,request='actor',subject='self',observed={}}},'bad_observed_cursor_type'),
        'an observed signature without a cursor_type is rejected')
    check(invalid({{index=1,request='actor',subject='self',observed={cursor_type=7}}},
        'bad_observed_cursor_type'),'a non-string cursor_type is rejected')
    check(invalid({{index=1,request='actor',subject='self',observed={cursor_type='hit',range=10}}},
        'unknown_observed_key'),'a dynamic numeric (range) is not a signature field')
    check(invalid({{index=1,request='actor',subject='self',observed={cursor_type='hit',nolock='yes'}}},
        'bad_observed_flag'),'a non-boolean signature flag is rejected')
    check(invalid({{index=1,request='actor',subject='self',observed={cursor_type='hit',first_target=1}}},
        'bad_observed_string'),'a non-string signature string is rejected')
    check(invalid({{index=1,request='actor',subject='self',observed={cursor_type='hit',default_target='friend'}}},
        'bad_observed_default_target'),'a default_target other than self is rejected')
    -- A hole in the array is `request_sequence_not_array` (the dense-array rule).
    local holed={[1]={index=1,request='actor',subject='self',observed=ACTOR_SIG},
        [3]={index=3,request='grid',subject='self',observed=GRID_SIG}}
    local out,err=seq(holed)
    check(out==nil and err.detail=='request_sequence_not_array','a hole in the sequence is rejected')
    -- target_requests disagreement (length and kind) is invalid.
    local mismatch,merr=seq({{index=1,request='actor',subject='self',observed=ACTOR_SIG}},
        {target_requests={'grid'}})
    check(mismatch==nil and merr.detail=='request_sequence_kind_mismatch',
        'a target_requests kind disagreement is rejected')
    local length,lengErr=seq({{index=1,request='actor',subject='self',observed=ACTOR_SIG}},
        {target_requests={'actor','grid'}})
    check(length==nil and lengErr.detail=='request_sequence_length_mismatch',
        'a target_requests length disagreement is rejected')
    -- S2-R3-01 rev5: for N>=2 no entry's signature may SUBSUME another's
    -- (presence-explicit semantics). Identical records are the trivial case.
    local ambiguous,ambErr=seq({{index=1,request='actor',subject='self',observed=ACTOR_SIG},
        {index=2,request='grid',subject='self',observed=ACTOR_SIG}})
    check(ambiguous==nil and ambErr.reason=='movement_adapter_invalid'
        and ambErr.detail=='request_signature_ambiguous'
        and ambErr.indexes and ambErr.indexes[1]==1 and ambErr.indexes[2]==2,
        'identical signatures on N>=2 are movement_adapter_invalid/request_signature_ambiguous')
    -- Strict subsumption: under presence semantics an entry whose declared
    -- field-set strictly contains the other's (equal values on the shared
    -- fields, identical flag constraint sets) is ALWAYS-TRUE-redundant — every
    -- prompt matching the subsumed entry also matches the subsumer, so the
    -- subsumed entry can never be uniquely matched. Rejected at build time.
    local subsume,subsumeErr=seq({{index=1,request='actor',subject='self',
            observed={cursor_type='hit',nolock=true}},
        {index=2,request='grid',subject='self',
            observed={cursor_type='hit',nolock=true,first_target='friend'}}})
    check(subsume==nil and subsumeErr.reason=='movement_adapter_invalid'
        and subsumeErr.detail=='request_signature_ambiguous'
        and subsumeErr.indexes[1]==1 and subsumeErr.indexes[2]==2,
        'a strictly subsuming signature pair (more specific entry is redundant) is rejected')
    -- The former wildcard-overlap pair is now PROVABLY SAFE under presence
    -- semantics: a declared flag is present-and-equal and an undeclared flag
    -- must NOT be raised, so no constructed spec matches both entries.
    local overlap=assert(seq({{index=1,request='actor',subject='self',
            observed={cursor_type='hit'}},
        {index=2,request='grid',subject='self',observed={cursor_type='hit',nowarning=true}}}))
    check(#overlap.request_sequence==2,
        'presence semantics distinguishes a declared flag from its absence (overlap pair admitted)')
    -- The nil-vs-false pair is likewise safe: a declared `false` requires the
    -- key PRESENT with value `false`, which absence does not satisfy.
    local nilFalse=assert(seq({{index=1,request='actor',subject='self',
            observed={cursor_type='hit'}},
        {index=2,request='grid',subject='self',observed={cursor_type='hit',nolock=false}}}))
    check(#nilFalse.request_sequence==2,
        'a declared false flag is a real presence constraint (nil-vs-false pair admitted)')
    -- Vault's own shape (techniques/agility.lua:113,119): both prompts are
    -- `hit`-shaped and differ ONLY by nolock presence — cleanly distinguishable
    -- under presence semantics and admitted as a two-entry program.
    local vaultPair=assert(seq({{index=1,request='actor',subject='actor',
            observed={cursor_type='hit'}},
        {index=2,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='hit',nolock=true}}}))
    check(#vaultPair.request_sequence==2,
        'Vault-style hit-without-nolock vs hit+nolock is admitted (presence semantics)')
    -- Distinguishable-by-different-declared-discriminators pairs stay admitted.
    local distinct=assert(seq({{index=1,request='actor',subject='self',observed=ACTOR_SIG},
        {index=2,request='grid',subject='self',observed={cursor_type='hit',nolock=true}}}))
    check(#distinct.request_sequence==2,
        'entries differing by declared discriminators are accepted as distinct')
    -- The Phase Door shape pair stays admitted: differing cursor_type values
    -- are incompatible constraints on a field both entries declare.
    local phaseDoor=assert(seq({{index=1,request='actor',subject='self',observed=ACTOR_SIG},
        {index=2,request='grid',subject='self',observed=GRID_SIG}}))
    check(#phaseDoor.request_sequence==2,
        'entries whose cursor_type differs are admitted')
    -- A template with a sequence but no curated target_requests derives the list.
    check(valid.target_requests~=nil and #valid.target_requests==2,
        'the capability list is derived when omitted')
    -- S2-R3-01 rev5: the runtime carrier carries NO pairwise rejection — the
    -- runtime EXACTLY-ONE gate is the normative rule and subsumes it.
    local direct=Actions.validate({type='use_talent',talent_id='T_SEQ',
        sequence={{kind='self',request='actor',observed={cursor_type='hit'}},
            {kind='grid',x=3,y=3,request='grid',observed={cursor_type='hit',nolock=false}}}})
    check(direct~=nil,
        'a presence-distinguishable directly submitted pair stays valid')
end

-- 2. Planner lowering: one plan per declared entry, in order ------------------
do
    local movement=assert(Factory.expand('request_then_landing',{
        request_sequence={{index=1,request='actor',subject='self',observed=ACTOR_SIG},
            {index=2,request='grid',subject='self',value_source='target_plan',
                landing_from='envelope',observed=GRID_SIG}},
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
    -- S2-FIX5: no deviation record can be emitted without its identifying
    -- fields — every deviation surfaced by this production harness is
    -- shape-checked against `Actions.validateDeviation`.
    if result.sequence_deviation then
        local valid,err=Actions.validateDeviation(result.sequence_deviation)
        assert(valid,'deviation record shape violated: '..tostring(err))
    end
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
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG}}})
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
            sequence={{kind='self',request='actor',observed=ACTOR_SIG}}},nil)
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
            landing_from='envelope',observed=GRID_SIG}},
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
    check(plan.values[1].observed and plan.values[1].observed.cursor_type=='ball',
        'the curated observed signature rides with the decided value (the executor carrier)')
end

-- 3d. S2 rev3: since the executor matches the observed signature, a different
-- SPEC that carries the same declared discriminators still matches, and the
-- cursor_type alone is sufficient when it is the only declared field.
do
    local movement=assert(Factory.expand('request_then_landing',{
        request_sequence={{index=1,request='grid',subject='self',value_source='target_plan',
            landing_from='envelope',observed={cursor_type='hit'}}},
        delivery='teleport',landing='random',center='requested_grid',traverses=false,
        relocates_other=false,radius=1,min_radius=0,range=10}))
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local provider={origin=function() return {x=2,y=2} end,
        anchor=function() return {x=2,y=2} end,
        knowledge=function() return {in_bounds=true,visible=true,passable=true,hazard=false} end}
    local plan=assert(Planner.planSequence({talent='T_X',target='self',
        target_plan={{request='grid',destination={selector='position',x=6,y=2,accept=accept}}}},
        provider,movement,{x=2,y=2}))
    -- A grid-semantics prompt may legitimately be raised with the `hit` shape
    -- (Dimensional Step does exactly this); a curated signature saying so must
    -- be accepted. Presence-explicit semantics: the signature must declare
    -- every allowlisted discriminator the prompt raises (nowarning=true here);
    -- non-allowlisted observed fields (range/radius) are ignored.
    local seen={}
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function(self,answers) seen=answers;return true end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='grid',x=5,y=3,observed={cursor_type='hit',nowarning=true}}}})
    check(result.ok and seen[1] and seen[1].x==5 and seen[1].y==3,
        'a legal grid-via-hit request is accepted when the curated signature says so')
    -- Presence-explicit negative: the same prompt with an allowlisted flag the
    -- signature does NOT declare (nolock raised, undeclared) is a mismatch —
    -- the prompt is handed back, never answered blindly.
    local seen2={}
    local def2={prompts={{type='hit',range=10,nowarning=true,nolock=true}},
        on_answer=function(self,answers) seen2=answers;return true end}
    local result2=runQueue(def2,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='grid',x=5,y=3,
                observed={cursor_type='hit',nowarning=true}}}})
    check(not result2.ok and result2.code=='unexpected_target_request'
        and result2.sequence_deviation.handed_back==true
        and seen2[1] and seen2[1].x==99,
        'an allowlisted flag raised but undeclared by the signature is a zero-match handback')
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
        sequence={{kind='actor',request='actor',target_id='a1',observed=ACTOR_SIG},
            {kind='grid',request='grid',x=6,y=1,observed=GRID_SIG}}},
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
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,optional=true,observed=GRID_SIG}}})
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
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG}}})
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
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a third prompt past the declared sequence is unexpected')
    check(result.sequence_deviation.exhausted==true
        and result.sequence_deviation.observed.index==3,
        'an extra prompt reports the exhausted sequence and observed index 3')
    -- S2 rev3: the extra prompt's OBSERVED SHAPE is recorded (there is no
    -- declared entry for it, so no signature to match).
    check(result.sequence_deviation.observed_shape=='ball'
        and result.sequence_deviation.handed_back==true
        and command.target_handed_back=='unexpected_target_request'
        and command.target_cancelled==nil,
        'an extra prompt hands the live prompt back (handed_back, never target_cancelled)')
end

-- 8. Wrong-kind decided value pauses typed (never a wrong answer) -------------
-- The prompt matches its curated signature (the flow is what was reviewed); the
-- internal carrier still holds a value whose KIND cannot answer that prompt. The
-- value is never answered blindly: the executor cancels the native prompt with
-- the typed deviation (there is no correct value to hand the player either).
do
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return true end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='actor',x=5,y=3,observed=ACTOR_SIG}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a decided value whose kind cannot answer the declared prompt is unexpected')
    check(result.sequence_deviation.expected.request=='actor'
        and result.sequence_deviation.observed.request=='grid',
        'the wrong-kind deviation reports expected/observed kinds')
    check(result.sequence_deviation.handed_back==nil
        and command.target_cancelled=='unexpected_target_request',
        'an internal value-kind deviation is not a live handback')
end

-- 9. Unevaluable value pauses with movement_request_value_unknown -------------

-- 9b. S2 rev3: a reordered NATIVE flow. The declared program is actor-then-grid
-- (curated signatures hit-then-ball), but the native body raises the ball prompt
-- first. The observed signature at index 1 does not match the entry curated for
-- that position, so the flow is `unexpected_target_request` (never
-- `action_complete`), the live prompt is HANDED BACK, and the k-th declared
-- value is never blindly answered to the wrong prompt.
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
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a reordered native flow is the typed unexpected_target_request, not action_complete')
    local deviation=result.sequence_deviation
    check(deviation and deviation.expected.index==1 and deviation.expected.request=='actor'
        and deviation.observed.index==1 and deviation.observed_shape=='ball'
        and deviation.handed_back==true and deviation.skippable==false,
        'the reorder deviation reports the declared actor entry vs the observed ball shape')
    check(command.target_handed_back=='unexpected_target_request'
        and command.target_cancelled==nil,
        'a live reorder records target_handed_back, never target_cancelled')
    -- The queue never answered: both prompts were handed to the real native
    -- target request (the metatable seam), so the declared self/grid values are
    -- absent from the native flow and no wrong target was supplied.
    check(seen[1] and seen[1].x==99 and seen[1].y==99 and seen[1].entity==nil,
        'the first (ball) prompt was handed back to the player, unanswered by the queue')
    check(seen[2] and seen[2].x==99 and seen[2].entity==nil,
        'the second (hit) prompt was handed back to the player as well')
    check(seen[1].x~=1 and seen[2].x~=5,
        'the k-th declared values were never supplied to the reordered prompts')
    check(command.target_sequence and #command.target_sequence==2,
        'both observed prompts are still recorded for evidence')
end

-- 9c. S2 rev3: a spec the bridge CANNOT read as a signature (`typ` not a table,
-- or `typ.type` not a string) is `movement_request_kind_unknown` with
-- observed_shape=nil. The live prompt is handed back; the plugin never answers
-- blindly.
do
    local def={prompts={{type=7,range=10,nowarning=true}},
        on_answer=function() return true end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG}}})
    check(not result.ok and result.code=='movement_request_kind_unknown',
        'an unreadable native spec is a typed deviation, never a blind answer')
    local deviation=result.sequence_deviation
    check(deviation and deviation.expected.request=='actor'
        and deviation.observed_shape==nil and deviation.skippable==false
        and deviation.handed_back==true,
        'the kind-unknown deviation reports observed_shape=nil and the handback')
    check(command.target_handed_back=='movement_request_kind_unknown'
        and command.target_cancelled==nil,
        'the unreadable spec is a live handback (never target_cancelled)')
end
-- 9c-2. A READABLE spec that matches no declared entry is NOT kind_unknown: it
-- is unexpected_target_request with the observed shape (the narrowed trigger).
do
    local def={prompts={{type='mcp_unknown_shape',range=10,nowarning=true}},
        on_answer=function() return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'an unknown-but-readable shape is unexpected_target_request, not kind_unknown')
    check(result.sequence_deviation.observed_shape=='mcp_unknown_shape',
        'the readable-but-unmatched deviation reports its observed shape')
end
-- 9c-3. A curated `default_target='self'` matches only when the observed spec
-- carries the caster as default_target.
do
    local def={prompts={{type='hit',range=10,nowarning=true,default_target=true}},
        on_answer=function() return true end}
    -- `default_target=true` is not the caster: the declared default_target='self'
    -- does not match, so the prompt is handed back.
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',
                observed={cursor_type='hit',nowarning=true,default_target='self'}}}})
    check(not result.ok and result.code=='unexpected_target_request',
        "a declared default_target='self' does not match a non-caster default_target")
end
do
    -- With the caster as default_target the same signature matches.
    local p=player({T_SEQ={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return true end}},{x=1,y=1})
    p.default_target_ref=p
    local g={player=p,level={map={w=20,h=20}}}
    local def=p.talents_def.T_SEQ
    def.prompts={{type='hit',range=10,nowarning=true,default_target=p}}
    local command={command_id='c1'}
    local result=Actions.execute(g,{type='use_talent',talent_id='T_SEQ',
        sequence={{kind='self',request='actor',
            observed={cursor_type='hit',nowarning=true,default_target='self'}}}},nil,meta,command)
    check(result.ok,"a declared default_target='self' matches an observed caster default_target")
end
do
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return true end}
    -- An actor-kind value with no resolvable bound actor (the target argument is
    -- nil) is the plugin's own uncomputability boundary.
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='actor',request='actor',target_id='a1',observed=ACTOR_SIG}}})
    check(not result.ok and result.code=='movement_request_value_unknown',
        'an unevaluable decided value is the typed movement_request_value_unknown')
    check(result.sequence_deviation.dependency=='bound_actor'
        and result.sequence_deviation.index==1,
        'the value-unknown deviation carries the index and dependency')
end


-- 9d. S2 rev3: a SAME-KIND reorder. Two `grid` entries with distinct signatures
-- (`cone` then `ball`); the native body raises the `ball` prompt first, so the
-- observed signature at index 1 does not match the entry curated there. Detected
-- as unexpected_target_request; the declared coordinate is never consumed.
do
    local seen={}
    local def={prompts={{type='ball',range=14,radius=1,nowarning=true}},
        on_answer=function(self,answers) seen=answers;return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='grid',x=4,y=3,observed={cursor_type='cone'}},
                {kind='grid',request='grid',x=5,y=3,observed={cursor_type='ball'}}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a same-kind reorder is detected via the signature mismatch (never action_complete)')
    check(result.sequence_deviation.expected.index==1
        and result.sequence_deviation.observed_shape=='ball'
        and result.sequence_deviation.handed_back==true,
        'the same-kind reorder deviation reports the index and observed shape')
    check(seen[1] and seen[1].x==99 and seen[1].x~=4,
        'the first declared coordinate was never supplied to the reordered prompt')
end

-- 9e. A `self` entry whose curated signature is `hit`, answered with the caster
-- cell (the legal self-on-hit combination).
do
    local seen={}
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function(self,answers) seen=answers;return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='self',observed={cursor_type='hit',nowarning=true}}}})
    check(result.ok,'a self-on-hit program is answered per its curated signature')
    check(seen[1] and seen[1].x==1 and seen[1].y==1 and seen[1].entity~=nil,
        'the self prompt is answered with the caster cell and entity')
end

-- 9f. S2 rev3 classifier falsification: the SAME geometry can carry either
-- semantics, so a legal actor-via-`ball` and a legal grid-via-`hit` are both
-- accepted when the curated signature says so (the geometry-era classifier
-- falsely rejected these).
do
    local seen={}
    local def={prompts={{type='ball',range=10,nowarning=true}},
        on_answer=function(self,answers) seen=answers;return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',
                observed={cursor_type='ball',nowarning=true}}}})
    check(result.ok and seen[1] and seen[1].x==1 and seen[1].y==1,
        'a legal actor-semantics-via-ball request is accepted when the curated signature says so')
end

-- 9g. Vault (techniques/agility.lua:113,119): the two prompts BOTH raise
-- type='hit' and differ ONLY by nolock presence — the presence-explicit
-- presence rule is what makes the two-entry program executable. The second
-- prompt must be answered with its OWN decided value (the policy's landing
-- coordinate), not the actor prompt's value.
do
    local seen={}
    local def={prompts={{type='hit',range=10},
            {type='hit',nolock=true,range=5}},
        on_answer=function(self,answers) seen=answers;return true end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='actor',request='actor',target_id='a1',
                    observed={cursor_type='hit'}},
                {kind='grid',request='grid',x=6,y=2,
                    observed={cursor_type='hit',nolock=true}}}},
        {x=3,y=2})
    check(result.ok,'the Vault-style two-entry hit program settles in one submission')
    check(seen[1] and seen[1].x==3 and seen[1].y==2 and seen[1].entity~=nil
        and seen[2] and seen[2].x==6 and seen[2].y==2 and seen[2].entity==nil,
        'the second (nolock) prompt is answered with its own decided coordinate, not the actor value')
    local seq=command and command.target_sequence
    check(seq and #seq==2 and seq[1].shape=='hit' and seq[2].shape=='hit'
        and seq[1].answer.x==3 and seq[2].answer.x==6,
        'the observed sequence records both same-shape prompts and their distinct answers')
end

-- 10a. Exactly-one violations (S2-R3-01 rev5): an ambiguous declaration (two
-- identical signatures in a directly submitted sequence — the carrier no
-- longer rejects records pairwise) makes BOTH entries match the first prompt;
-- the prompt is handed back with the matched indexes, never answered.
do
    local seen={}
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function(self,answers) seen=answers;return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=ACTOR_SIG}}})
    check(not result.ok and result.code=='unexpected_target_request'
        and result.sequence_deviation.handed_back==true
        and result.sequence_deviation.matched_indexes
        and result.sequence_deviation.matched_indexes[1]==1
        and result.sequence_deviation.matched_indexes[2]==2,
        'an ambiguous declaration (two entries matching one prompt) hands the prompt back')
    check(seen[1] and seen[1].x==99,
        'the ambiguous prompt was never answered with either declared value')
    -- Zero-match: the raised prompt matches NO declared entry (extra/drifted).
    local seen2={}
    local def2={prompts={{type='cone',range=10,nowarning=true}},
        on_answer=function(self,answers) seen2=answers;return true end}
    local result2=runQueue(def2,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG}}})
    check(not result2.ok and result2.code=='unexpected_target_request'
        and result2.sequence_deviation.matched_indexes and #result2.sequence_deviation.matched_indexes==0,
        'a zero-match prompt (matches no declared entry) is a typed handback')
    check(seen2[1] and seen2[1].x==99,
        'the zero-match prompt was never answered')
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
        sequence={{kind='self',observed=ACTOR_SIG},{kind='grid',x=3,y=4,observed=GRID_SIG}}})
    check(normalized and normalized.authoritative_target==true,
        'a valid sequence implies the authoritative wrapper')
    check(normalized.sequence[1].observed.cursor_type=='hit',
        'the curated observed signature is carried on the internal sequence field')
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='self'}}}),
        'a sequence entry without a curated observed signature is invalid_sequence')
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='self',observed={cursor_type='hit',radius=3}}}}),
        'a dynamic numeric in the observed signature is invalid_sequence (not a signature field)')
    check(Actions.fingerprint({type='use_talent',talent_id='T_A',sequence={{kind='grid',x=3,y=4,observed=GRID_SIG}}},1)
        ~=Actions.fingerprint({type='use_talent',talent_id='T_A',sequence={{kind='grid',x=3,y=5,observed=GRID_SIG}}},1),
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

-- 15. S2-FIX5: the deviation shape gate -------------------------------
-- Every emission site asserts `Actions.validateDeviation`, so a deviation
-- record can never be stored (or surfaced on a result/pause) without its
-- identifying fields. These checks pin the contract itself.
do
    check(Actions.validateDeviation({reason='unexpected_target_request',
        expected={index=1,request='actor'},observed={index=1,request='grid'},
        skippable=false})==true,
        'a complete unexpected_target_request record validates')
    check(Actions.validateDeviation({reason='movement_request_kind_unknown',
        expected={index=1,request='actor'},observed={index=1,request=nil},
        observed_shape='ball',handed_back=true,skippable=false})==true,
        'a complete movement_request_kind_unknown record validates')
    check(Actions.validateDeviation({reason='movement_request_value_unknown',
        expected={index=1,request='actor'},observed={index=1,request=nil},
        index=1,request='actor',dependency='bound_actor',skippable=false})==true,
        'a complete movement_request_value_unknown record validates')
    local function bad(record,why)
        local valid,err=Actions.validateDeviation(record)
        check(valid==false and err==why,'an incomplete deviation record is rejected ('..why..')')
    end
    bad(nil,'record_not_table')
    bad({expected={index=1},observed={index=1},skippable=false},'missing_reason')
    bad({reason='unexpected_target_request',observed={index=1},skippable=false},'missing_expected')
    bad({reason='unexpected_target_request',expected={index=1},skippable=false},'missing_observed')
    bad({reason='unexpected_target_request',expected={index=1},observed={index=1}},'missing_skippable')
    bad({reason='movement_request_kind_unknown',expected={index=1,request='actor'},
        observed={index=1},skippable=false},'missing_handed_back')
    bad({reason='movement_request_value_unknown',expected={index=1,request='actor'},
        observed={index=1},index=1,request='actor',skippable=false},'missing_dependency')
    bad({reason='movement_request_value_unknown',expected={index=1,request='actor'},
        observed={index=1},request='actor',dependency='self',skippable=false},'missing_index')
    bad({reason='not_a_typed_reason',expected={index=1},observed={index=1},
        skippable=false},'unknown_reason')
    bad({reason='unexpected_target_request',expected='actor',observed={index=1},
        skippable=false},'invalid_expected')
    bad({reason='unexpected_target_request',expected={index=1},observed='grid',
        skippable=false},'invalid_observed')
end

-- 16. S2-FIX5: a native entry that refuses BEFORE any prompt (cooldown /
-- no energy / on_pre_use) never enters the targeting flow, so the queue
-- observes ZERO prompts. That is the ordinary native rejection — never a
-- fabricated unexpected_target_request, never a target_cancelled.
do
    local p=player({T_SEQ={prompts={{type='hit',range=10,nowarning=true},
            {type='ball',range=14,radius=1,nowarning=true}},
        on_answer=function() return true end}},{x=1,y=1})
    p.talents_cd={T_SEQ=11}
    local def=p.talents_def.T_SEQ
    -- Mirror the real native entry (ActorTalents isTalentCoolingDown): the
    -- cooldown check returns false BEFORE the coroutine/getTarget flow, so no
    -- prompt is ever raised and the queue settles with zero observed prompts.
    def.action=function(self)
        if (self.talents_cd or {})[def.id] and self.talents_cd[def.id]>0 then return false end
        return scriptedAction(def)(self)
    end
    local g={player=p,level={map={w=20,h=20}}}
    local command={command_id='c1'}
    local result=Actions.execute(g,{type='use_talent',talent_id='T_SEQ',
        sequence={{kind='self',request='actor',observed=ACTOR_SIG},
            {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG}}},nil,meta,command)
    check(not result.ok and result.code=='native_rejected',
        'a pre-prompt cooldown refusal is the ordinary native_rejected outcome')
    check(result.sequence_deviation==nil,
        'a pre-prompt refusal never fabricates a sequence deviation')
    check(command.target_cancelled==nil and command.target_handed_back==nil,
        'a pre-prompt refusal carries no target_cancelled and no handback')
    check(result.native_return==false,
        'the native false return is preserved on the result')
    check(result.target_sequence and #result.target_sequence==0,
        'the observed prompt sequence stays empty (zero prompts raised)')
    check(result.missing and result.missing[1] and result.missing[1].kind=='cooldown'
        and result.missing[1].talent=='T_SEQ' and result.missing[1].remaining==11,
        'the ordinary refusal carries its own structured cooldown detail')
    check(type(result.hint)=='string' and result.hint:find('cooldown',1,true)~=nil,
        'the ordinary refusal carries the cooldown hint')
end

-- 16. S2-FIX5: a genuine mid-sequence abort still deviates; the deviation
-- record carries its identifying fields (expected/observed/skippable).
do
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a genuine mid-sequence abort (first prompt answered, second never raised) still deviates')
    check(Actions.validateDeviation(result.sequence_deviation)==true,
        'the mid-sequence abort deviation carries its identifying fields')
    check(result.sequence_deviation.expected.index==2
        and result.sequence_deviation.skippable==false,
        'the mid-sequence abort keeps its expected/skippable fields')
end

-- 16b. S2-FIX5: a trailing-optional non-raise keeps its meaning: the settled
-- native outcome is reported reduced, with no deviation record at all.
do
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,optional=true,observed=GRID_SIG}}})
    check(result.ok and result.reduced==true
        and result.reduced_reason=='trailing_optional_not_raised'
        and result.sequence_deviation==nil,
        'a trailing-optional non-raise is still the settled reduced outcome')
end

-- 16c. S2-FIX5-R1: a zero-prompt TRUTHY native return is NOT a refusal. The
-- `raised` exemption applies only to a pre-prompt native FAILURE, so a declared
-- non-optional sequence whose prompts were never consumed still surfaces the
-- typed missing-sequence deviation: the action must never be reported as
-- `action_complete` with an empty target_sequence.
do
    local def={prompts={},on_answer=function() return true end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'a zero-prompt truthy return on a non-optional sequence is not action_complete')
    check(result.sequence_deviation~=nil and result.sequence_deviation.reason=='unexpected_target_request',
        'the zero-prompt success surfaces the typed missing-sequence deviation')
    check(result.sequence_deviation.expected.index==1
        and result.sequence_deviation.expected.request=='actor'
        and result.sequence_deviation.observed.index==1
        and result.sequence_deviation.observed.request==nil
        and result.sequence_deviation.skippable==false,
        'the zero-prompt success deviation carries expected/observed/skippable')
    check(result.target_sequence and #result.target_sequence==0,
        'the zero-prompt success records an empty observed prompt sequence')
    check(command.target_cancelled=='unexpected_target_request',
        'the zero-prompt success carries the typed cancel marker')
end

-- 16d. S2-FIX5-R1: a zero-prompt FALSY native return (no cooldown branch, just a
-- plain pre-prompt refusal) stays the ordinary native rejection with no
-- deviation — the narrow exemption is the pre-prompt failure itself.
do
    local def={prompts={},on_answer=function() return false end}
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG}}})
    check(not result.ok and result.code=='native_rejected',
        'a plain zero-prompt falsy return is the ordinary native_rejected outcome')
    check(result.sequence_deviation==nil,
        'a plain zero-prompt falsy return never fabricates a deviation')
    check(command.target_cancelled==nil,
        'a plain zero-prompt falsy return carries no target_cancelled')
end

-- 16e. S2-FIX5-R1: one prompt raised and then a falsy return is NOT a pre-prompt
-- refusal — the missing non-optional successor still deviates at its index.
do
    local def={prompts={{type='hit',range=10,nowarning=true}},
        on_answer=function() return false end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG}}})
    check(not result.ok and result.code=='unexpected_target_request',
        'one prompt then a falsy return still deviates')
    check(result.sequence_deviation~=nil
        and result.sequence_deviation.expected.index==2
        and result.sequence_deviation.skippable==false,
        'the one-prompt-then-false deviation is at the missing index')
end

-- 16f. S2-FIX5-R1: a MIXED sequence whose ONLY missing entry is the trailing
-- `optional`, with a truthy native return, is still the settled reduced outcome
-- (not a deviation) — the narrow exemption must not over-reach the other way.
do
    local def={prompts={{type='hit',range=10,nowarning=true},
            {type='ball',range=14,radius=1,nowarning=true}},
        on_answer=function() return true end}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='self',request='actor',observed=ACTOR_SIG},
                {kind='grid',request='grid',x=5,y=3,observed=GRID_SIG},
                {kind='grid',request='grid',x=7,y=7,optional=true,
                    observed={cursor_type='beam',nowarning=true}}}})
    check(result.ok and result.code=='action_complete'
        and result.reduced==true
        and result.reduced_reason=='trailing_optional_not_raised'
        and result.sequence_deviation==nil,
        'a trailing-optional-only miss with a truthy return is action_complete + reduced')
end


-- 15. A′ §6.1/§6.3: in-group matching relaxation, arrival index preserved -----
-- The native body raises the SAME prompt shape N times (the real Earthen
-- Missiles local bolt specs, `spells/stone.lua:38,45,53` / the Dwarven twin at
-- `gifts/dwarven-nature.lua:34,41,49`). The declared group says those prompts
-- are mutually unidentifiable, so the executor may answer the k-th OBSERVED
-- prompt with plan[k] even when it also matches its siblings. Nothing is
-- re-mapped: arrival k -> plan[k], always. A matched set that EXCLUDES the
-- expected arrival index is always a typed deviation.
local BOLT_SIG={cursor_type='bolt'}
local function boltGroupMovement(count,group)
    local seq={}
    for i=1,count do
        seq[i]={index=i,request='grid',subject='self',value_source='target_plan',
            observed=BOLT_SIG,group=group}
    end
    return assert(Factory.expand('stationary_sequence',{request_sequence=seq,range=10}))
end
local function boltPlayer()
    local seen={}
    -- The native body raises the same-shape bolt prompt once per declared answer
    -- and records every answer, exactly like the reviewed missile loop
    -- (`spells/stone.lua:46-56` raises the next bolt only while the previous
    -- answer was non-nil). The recorded answers live in a shared holder table.
    local def={stop_on_cancel=true,
        on_answer=function(self,answers) seen.answers=answers;return true end}
    def.prompts={}
    for _=1,3 do def.prompts[#def.prompts+1]={type='bolt',range=10} end
    return def,seen
end
do
    -- The observed answer record is exactly arrival 1->V1, 2->V2, 3->V3.
    local def,seen=boltPlayer()
    local result,command=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='grid',x=5,y=3,observed=BOLT_SIG,group='em'},
                {kind='grid',request='grid',x=6,y=3,observed=BOLT_SIG,group='em'},
                {kind='grid',request='grid',x=7,y=3,observed=BOLT_SIG,group='em'}}})
    check(result.ok and result.sequence_deviation==nil,
        'a three-member in-group program settles in one submission with no deviation')
    local answers=seen.answers
    check(answers and answers[1] and answers[1].x==5 and answers[1].y==3
        and answers[2] and answers[2].x==6 and answers[2].y==3
        and answers[3] and answers[3].x==7 and answers[3].y==3,
        'arrival k is answered with plan[k] for every member (no re-mapping)')
    local seq=result.target_sequence
    check(seq and #seq==3 and seq[1].answer.x==5 and seq[2].answer.x==6 and seq[3].answer.x==7,
        'the observed sequence records the positional answers')
    check(seq[1].answer.x<seq[2].answer.x and seq[2].answer.x<seq[3].answer.x,
        'the answered coordinates follow the arrival order exactly')
end
do
    -- A non-member match inside a declared group is a typed deviation: at
    -- arrival 1 the matched set is {1,2,3} and entry 3 is not a member of g1.
    local def,seen=boltPlayer()
    def.prompts={def.prompts[1]}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='grid',x=5,y=3,observed=BOLT_SIG,group='g1'},
                {kind='grid',request='grid',x=6,y=3,observed=BOLT_SIG,group='g1'},
                {kind='grid',request='grid',x=7,y=3,observed=BOLT_SIG}}})
    check(result.ok==false and result.code=='unexpected_target_request'
        and result.sequence_deviation.handed_back==true,
        'a non-member match inside a group is a typed unexpected_target_request handback')
    check(result.sequence_deviation.matched_indexes
        and result.sequence_deviation.matched_indexes[1]==1
        and result.sequence_deviation.matched_indexes[2]==2
        and result.sequence_deviation.matched_indexes[3]==3,
        'the deviation reports every matched index')
    check(seen.answers and seen.answers[1] and seen.answers[1].x==99,
        'the non-member prompt was never answered with a declared value')
end
do
    -- Cross-group: a raised prompt matching only ANOTHER group at this arrival
    -- is a deviation (the expected arrival index is not in the matched set).
    local def,seen=boltPlayer()
    def.prompts={def.prompts[1]}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='grid',x=5,y=3,
                    observed={cursor_type='bolt',nolock=true},group='g1'},
                {kind='grid',request='grid',x=6,y=3,
                    observed={cursor_type='bolt',nolock=true},group='g1'},
                {kind='grid',request='grid',x=7,y=3,
                    observed={cursor_type='bolt'},group='g2'},
                {kind='grid',request='grid',x=8,y=3,
                    observed={cursor_type='bolt'},group='g2'}}})
    check(result.ok==false and result.code=='unexpected_target_request',
        'a raised prompt matching only another group at the expected arrival is a deviation')
    check(result.sequence_deviation.matched_indexes
        and #result.sequence_deviation.matched_indexes==2
        and result.sequence_deviation.matched_indexes[1]==3
        and result.sequence_deviation.matched_indexes[2]==4,
        'the cross-group deviation reports the OTHER group indexes')
    check(seen.answers and seen.answers[1] and seen.answers[1].x==99,
        'the cross-group prompt was never answered')
end
do
    -- Ambiguous UNGROUPED match (the pre-A′ behaviour) is unchanged: two
    -- identical ungrouped signatures hand the prompt back.
    local def,seen=boltPlayer()
    def.prompts={def.prompts[1]}
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='grid',x=5,y=3,observed=BOLT_SIG},
                {kind='grid',request='grid',x=6,y=3,observed=BOLT_SIG}}})
    check(result.ok==false and result.code=='unexpected_target_request'
        and #result.sequence_deviation.matched_indexes==2,
        'an ambiguous UNGROUPED match keeps the pre-existing handback behaviour')
    check(seen.answers and seen.answers[1] and seen.answers[1].x==99,
        'the ambiguous ungrouped prompt was never answered')
end
do
    -- A′ §6.3: the runtime carrier re-validates group membership, so a forged or
    -- weakened carrier is invalid_sequence and can never relax the gate.
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='grid',x=5,y=3,observed=BOLT_SIG,group='g1'}}}),
        'a forged single-member group on the carrier is invalid_sequence')
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='grid',x=5,y=3,observed=BOLT_SIG,group='g1'},
            {kind='grid',x=6,y=3,observed={cursor_type='bolt',nolock=true},group='g1'}}}),
        'a forged group whose signatures differ is invalid_sequence')
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='grid',x=5,y=3,observed=BOLT_SIG,group='Earthen Missiles (stone.lua)'},
            {kind='grid',x=6,y=3,observed=BOLT_SIG,group='Earthen Missiles (stone.lua)'}}}),
        'a forged group key carrying prose is invalid_sequence')
    -- R2-APR-03: the carrier re-validation uses the factory's SHARED signature
    -- normalizer and group validator, so a declaration the factory refuses is
    -- refused on the carrier too. (a) A 65-byte `first_target` (the factory
    -- bounds it to 64) is invalid_sequence; 64 stays admitted.
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='grid',x=5,y=3,observed={cursor_type='bolt',
                first_target=string.rep('a',65)},group='g1'},
            {kind='grid',x=6,y=3,observed={cursor_type='bolt',
                first_target=string.rep('a',65)},group='g1'}}}),
        'a 65-byte first_target the factory refuses is invalid_sequence on the carrier (R2-APR-03)')
    local ok64=Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='grid',x=5,y=3,observed={cursor_type='bolt',
                first_target=string.rep('a',64)},group='g1'},
            {kind='grid',x=6,y=3,observed={cursor_type='bolt',
                first_target=string.rep('a',64)},group='g1'}}})
    check(ok64 and ok64.sequence[1].observed.first_target==string.rep('a',64),
        'a 64-byte first_target stays admitted on the carrier (factory-identical bounds)')
    -- (b) An interleaved group — members at 1 and 3 around an ungrouped entry —
    -- is `group_not_contiguous` at BOTH boundaries (R2-APR2-02); the carrier
    -- must refuse it too (the reviewer's CARRIER_INTERLEAVED reproduction). The
    -- build-time half of the same shape is covered in
    -- `test_auto_combat_movement_factory.lua`.
    check(not Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='grid',x=5,y=3,observed=BOLT_SIG,group='g1'},
            {kind='grid',x=6,y=3,observed=BOLT_SIG},
            {kind='grid',x=7,y=3,observed=BOLT_SIG,group='g1'}}}),
        'an interleaved group is invalid_sequence on the carrier (R2-APR2-02, both boundaries)')
    -- The reviewer's GENERIC_INTERLEAVED_FACTORY reproduction: the factory now
    -- REFUSES the same interleaved generic group at build time, so the two
    -- boundaries accept the same language. (The build-time assertion lives in
    -- the factory suite; this is the carrier-side half of the pair.)
    local valid=Actions.validate({type='use_talent',talent_id='T_A',
        sequence={{kind='grid',x=5,y=3,observed=BOLT_SIG,group='g1'},
            {kind='grid',x=6,y=3,observed=BOLT_SIG,group='g1'}}})
    check(valid and valid.sequence[1].group=='g1',
        'a mechanically valid group rides the carrier unchanged')
    -- Case 9 (documenting, not detecting): a same-signature S1/S3/S2 source order
    -- is UNOBSERVABLE. The contract asserted here is arrival preservation, not
    -- source-slot identification: the k-th arrival is answered with plan[k].
    local def,seen=boltPlayer()
    local result=runQueue(def,
        {type='use_talent',talent_id='T_SEQ',
            sequence={{kind='grid',request='grid',x=5,y=3,observed=BOLT_SIG,group='em'},
                {kind='grid',request='grid',x=6,y=3,observed=BOLT_SIG,group='em'},
                {kind='grid',request='grid',x=7,y=3,observed=BOLT_SIG,group='em'}}})
    check(result.ok and seen.answers and seen.answers[2] and seen.answers[2].x==6,
        'a same-signature sequence preserves the ARRIVAL index (source-slot identity is not claimed)')
end

-- 16. Stationary lowering + plan-value closure (A′ §6.5) ----------------------
do
    local movement=boltGroupMovement(2,'em')
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local provider={origin=function() return {x=2,y=2} end,
        anchor=function() return {x=2,y=2} end,
        knowledge=function() return {in_bounds=true,visible=true,passable=true,hazard=false} end}
    local plan=assert(Planner.planSequence({talent='T_EARTHEN_MISSILES',target='self',
        target_plan={{request='grid',destination={selector='position',x=5,y=2,accept=accept}},
            {request='grid',destination={selector='position',x=6,y=2,accept=accept}}}},
        provider,movement,{x=2,y=2}))
    check(plan.kind=='sequence' and #plan.steps==2,
        'the stationary program lowers into the SAME kind=sequence plan (no second queue)')
    check(plan.values[1].group=='em' and plan.values[2].group=='em',
        'declared group membership rides the internal carrier')
    check(plan.annotation.stationary==true
        and plan.annotation.outcome_uncertainty=='per_projectile_random_crit',
        'the plan annotates the stationary delivery and the per-projectile crit uncertainty')
    check(plan.annotation.landing.kind=='deterministic',
        'a stationary aim grid stays a deterministic annotation (the caster does not move)')
    for i,value in ipairs(plan.values) do
        check(value.kind=='grid' and type(value.x)=='number' and type(value.y)=='number',
            'plan value '..i..' is a valid grid')
    end
    -- R2-APR-02 (both ways): the annotation derives from the TEMPLATE-DERIVED
    -- marker, never from a raw caller-authored enum. A hand-authored mover leaf
    -- that merely DECLARES `delivery='stationary'` (the bypass shape the factory
    -- now refuses at build time) is NOT annotated stationary.
    local forged={delivery='stationary',landing='exact',center='self',
        traverses=false,relocates_other=false,target_requests={'grid'},
        request_sequence={{index=1,request='grid',subject='self',
            value_source='target_plan',observed=BOLT_SIG}}}
    local forgedPlan=assert(Planner.planSequence({talent='T_FORGED',target='self',
        target_plan={{request='grid',destination={selector='position',x=5,y=2,accept=accept}}}},
        provider,forged,{x=2,y=2}))
    check(forgedPlan and forgedPlan.annotation.stationary~=true,
        'a marker-less leaf with a stationary delivery enum is never annotated stationary (R2-APR-02)')
    check(forgedPlan and forgedPlan.annotation.delivery~='stationary',
        'the annotation delivery stays empty for a non-template stationary enum')
end

print('Auto-combat ordered sequence: '..checks..' checks passed')
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
        request_sequence={{index=1,request='actor',subject='self',observed=ACTOR_SIG},
            {index=2,request='grid',subject='self',value_source='target_plan',landing_from='envelope',observed=GRID_SIG}},
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

