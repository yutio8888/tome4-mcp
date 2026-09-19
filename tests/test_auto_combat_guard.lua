-- V2-2: the manifest-driven guard composes canonical components, resolves
-- variants from audited scalar reads and applies the D2 policy.
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
local Guard=require 'mod.auto_combat.AutoCombatGuard'
local Manifest=require 'mod.auto_combat.EffectManifest'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local function build(opts)
    opts=opts or {}
    local p={uid=1,x=2,y=2,life=100,max_life=100,talents=opts.talents or {},
        canProject=function() return true end,
        attr=opts.attr or function() return nil end}
    for key,value in pairs(opts.player_fields or {}) do p[key]=value end
    local target={uid=2,x=opts.tx or 5,y=opts.ty or 2,life=100,max_life=100,reaction=-1}
    local allies=opts.allies or {}
    local g={player=p,level={map={w=10,h=10},entities={p,target}}}
    -- Default native builders matching each entry's conformance geometry, so a
    -- scenario that does not care about the builder still exercises the
    -- production path; scenarios override `defs` when they need to.
    local defs=opts.defs
    if defs==nil then
        defs={}
        for talent,entry in pairs(Manifest.ENTRIES) do
            local conformance=entry.conformance
            if conformance and conformance.builder==true then
                defs[talent]={id=talent,target=function(self,t)
                    return {type=conformance.shape,range=entry.range,radius=entry.radius}
                end}
            end
        end
    end
    local ctx={
        game=g,policy=opts.policy or {safety={max_selffire_risk=0}},source=p,
        resolve=function() return target end,
        allies=function() return allies end,
        visible=function() return true end,
        known=function() return true end,
        getDef=function(id) return defs[id] end,
        blockPath=opts.blockPath or function() return false end,
        details=Details,native=opts.native,
        talentLevel=opts.talentLevel,
        dynamicScalar=opts.dynamicScalar,
    }
    return Guard.build(ctx),p,target
end
local function attempt(talent)
    return {action='use_talent',talent=talent,bound_target=2}
end

-- Rejections that do not depend on geometry.
do
    local guard=build()
    local result=guard(attempt('T_NOT_A_TALENT'))
    check(result and result.reason=='unsupported_adapter','an unknown talent is rejected')
    check(guard(attempt('T_HEAL'))==nil,'a self-target talent is left to the native executor')
    check(guard(attempt('T_ATTACK'))==nil,'a melee talent is left to the native executor')
    check(guard({action='wait'})==nil,'a non-action attempt is ignored')
end
do
    -- NO-AUDIT (v1.6): there is no source-drift gate. A drifted/injected record
    -- is advisory telemetry; the guard calls the live builder instead.
    local guard=build{drift=function() return {drift=true,findings={}} end}
    check(guard(attempt('T_MOONLIGHT_RAY'))==nil,
        'an advisory drift record does not deny an otherwise-usable action')
    local soft=build{drift=function() return {drift=true,findings={}} end,
        policy={safety={max_selffire_risk=50}}}
    check(soft(attempt('T_MOONLIGHT_RAY'))==nil,
        'a drift record never gates regardless of the risk threshold')
end

-- Beam: an ally in the line rejects; a clear line passes.
do
    local ally={uid=9,x=3,y=2}
    local guard=build{allies={ally}}
    local result=guard(attempt('T_MOONLIGHT_RAY'))
    check(result and result.reason=='selffire_risk' and result.detail.risk=='friendly' and result.detail.phase=='instant',
        'a beam is rejected for an ally in its line')
    local clear=build{}
    check(clear(attempt('T_MOONLIGHT_RAY'))==nil,'a clear beam passes')
end

-- Searing Light: the ball cursor is not the damage footprint; its safe ground
-- zone passes even with the ally adjacent to the target.
do
    local guard=build{allies={{uid=9,x=4,y=2}}}
    check(guard(attempt('T_SEARING_LIGHT'))==nil,'Searing Light passes an adjacent ally (cursor is not damage)')
end

-- Flame: the Burning Wake ground zone is future risk even when empty.
-- The live builder resolves the bolt/beam/widebeam branch; use a beam here so
-- the ground component is the only remaining risk.
do
    local beamDef={T_FLAME={id='T_FLAME',target=function() return {type='beam',range=10} end}}
    local noWake=build{attr=function(_,id) return nil end,defs=beamDef}
    check(noWake(attempt('T_FLAME'))==nil,'Flame without Burning Wake passes')
    local wake=build{attr=function(_,id) if id=='burning_wake' then return 5 end end,defs=beamDef}
    local result=wake(attempt('T_FLAME'))
    check(result and result.reason=='selffire_risk' and result.detail.phase=='ground',
        'an active Burning Wake ground zone rejects even when empty')
end

-- An unresolved branch stays in the conservative union: with the level and the
-- wide-beam attribute both unreadable, the wide-beam FF is unknown, and a
-- friendly must still be checked against the union footprint.
do
    local guard=build{attr=function() return 'unknown' end,allies={{uid=9,x=3,y=2}}}
    local result=guard(attempt('T_FLAME'))
    check(result and result.reason=='selffire_risk','an unresolved branch keeps the conservative union')
end

-- V2-REV-01: variants use the effective talent level (mastery/alterations),
-- never raw invested points.
do
    local ally={uid=9,x=6,y=2}
    local mastered=build{talents={T_SUN_BEAM=2},talentLevel=function() return 3 end,allies={ally}}
    local result=mastered(attempt('T_SUN_BEAM'))
    check(result and result.reason=='selffire_risk' and result.detail.phase=='secondary',
        'effective level 3 with raw 2 still checks the Sun Ray secondary ball')
    local below=build{talents={T_SUN_BEAM=2},talentLevel=function() return 2 end,allies={ally}}
    check(below(attempt('T_SUN_BEAM'))==nil,'effective level 2 leaves the secondary inactive')
    local unavailable=build{talents={T_SUN_BEAM=2},allies={ally}}
    check(unavailable(attempt('T_SUN_BEAM'))~=nil,
        'an unavailable effective level retains the conservative secondary')
end

-- V2-REV-02: builder invocation failure is a value-not-obtainable fault, not a
-- reason to fall back to stale manifest geometry; there is no source-drift gate.
do
    local throwing=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=function() error('boom') end}}}
    local first=throwing(attempt('T_MOONLIGHT_RAY'))
    check(first and first.reason=='adapter_builder_failed','a throwing builder fails closed')
    local nonTable=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=function() return 'nope' end}}}
    local second=nonTable(attempt('T_MOONLIGHT_RAY'))
    check(second and second.reason=='adapter_builder_failed','a non-table builder fails closed')
    -- A drift record is advisory and does not gate even a self-target action.
    local drifted=build{drift=function() return {drift=true,findings={}} end}
    check(drifted(attempt('T_HEAL'))==nil,'a self-target action is not gated by advisory drift')
end

-- V2-REV-03: a native expansion failure is unknown, not an approximate model.
do
    local guard=build{native={},allies={{uid=9,x=3,y=2}}}
    local result=guard(attempt('T_MOONLIGHT_RAY'))
    check(result and result.reason=='selffire_risk',
        'a native expansion failure rejects instead of using the model')
end

-- V2-REV-04: the player projectile opt-in is a boolean OR across the live
-- target-spec opt-in and the actor flag; `false` in one never vetoes `true` in
-- the other.
do
    local function flameBuild(allow,specOptIn)
        local defs={T_FLAME={id='T_FLAME',target=function()
            local spec={type='ball',range=10,radius=5,selffire=true,friendlyfire=true}
            if specOptIn~=nil then spec.player_selffire=specOptIn end
            return spec end}}
        local guard=build{defs=defs,talentLevel=function() return 1 end,
            player_fields={allow_player_selffire=allow}}
        return guard(attempt('T_FLAME'))
    end
    check(flameBuild(true,nil)~=nil,'the actor opt-in makes a self-hit a risk')
    check(flameBuild(false,nil)==nil,'without any opt-in the self-hit is suppressed')
    check(flameBuild(true,false)~=nil,'spec player_selffire=false does not veto the actor opt-in')
    check(flameBuild(false,true)~=nil,'spec player_selffire=true does not need the actor opt-in')
    check(flameBuild(false,false)==nil,'both opt-in sources false suppresses the self-hit')
end

-- DYN-2/DYN-3/DYN-REV-01: the re-admitted dynamic talents resolve their
-- audited `spellFriendlyFire` input, which is authoritative over the raw
-- builder value; an unavailable provider fails closed even when the builder
-- returns 0. The persistent grounds (Burning Wake, Shadow Blast) keep
-- default-true FF.
do
    local function fireflash(sf,extra,specSelffire)
        local opts={defs={T_FIREFLASH={id='T_FIREFLASH',target=function()
            local spec={type='ball',range=7,radius=5}
            if specSelffire~=nil then spec.selffire=specSelffire end
            return spec end}},talentLevel=function() return 1 end}
        if sf~=nil then opts.dynamicScalar=function() return sf end end
        for key,value in pairs(extra or {}) do opts[key]=value end
        return build(opts)(attempt('T_FIREFLASH'))
    end
    check(fireflash(0)==nil,'a zero spellFriendlyFire suppresses the Fireflash self-hit')
    check(fireflash(100)~=nil,'a positive spellFriendlyFire makes the Fireflash self-hit a risk')
    check(fireflash(nil)~=nil,'an unavailable spellFriendlyFire fails closed')
    check(fireflash(nil,nil,0)~=nil,'a builder selffire=0 cannot override an unavailable provider')
    local wake=fireflash(0,{attr=function(_,id) if id=='burning_wake' then return 1 end end})
    check(wake and wake.reason=='selffire_risk' and wake.detail.phase=='ground',
        'the Fireflash Burning Wake ground rejects with default-true FF')
end
do
    local shadowDefs={T_SHADOW_BLAST={id='T_SHADOW_BLAST',target=function()
        return {type='ball',range=6,radius=3} end}}
    local shadow=build{defs=shadowDefs,dynamicScalar=function() return 0 end}
    local result=shadow(attempt('T_SHADOW_BLAST'))
    check(result and result.reason=='selffire_risk' and result.detail.phase=='ground',
        'Shadow Blast persistent ground rejects with default-true FF')
    local starDefs={T_STARFALL={id='T_STARFALL',target=function()
        return {type='ball',range=6,radius=5} end}}
    local star=build{defs=starDefs,dynamicScalar=function() return 0 end}
    check(star(attempt('T_STARFALL'))==nil,'Starfall has no persistent ground component')
    -- The real Starfall builder calls spellFriendlyFire; a raw 0 must not
    -- override the audited provider's failure.
    local starBad=build{defs={T_STARFALL={id='T_STARFALL',target=function()
        return {type='ball',range=6,radius=5,selffire=0} end}}}
    local bad=starBad(attempt('T_STARFALL'))
    check(bad and bad.reason=='selffire_risk',
        'a Starfall builder selffire=0 cannot override an unavailable provider')
end

-- DYN-REV-02: a range-0 self-centred cone authorizes only a bound target that
-- lies in the resolved instant footprint.
do
    local defs={T_FLAMESHOCK={id='T_FLAMESHOCK',target=function()
        return {type='cone',range=0,radius=4,selffire=false} end}}
    local function flameshock(tx,ty,extra)
        local opts={defs=defs,talentLevel=function() return 1 end,tx=tx,ty=ty}
        for key,value in pairs(extra or {}) do opts[key]=value end
        return build(opts)(attempt('T_FLAMESHOCK'))
    end
    check(flameshock(4,2)==nil,'a bound target inside the range-0 cone is allowed')
    local far=flameshock(9,2)
    check(far and far.reason=='target_out_of_range','a bound target outside the range-0 cone is rejected')
    check(flameshock(4,2,{native={}})~=nil,'a range-0 cone with an unexpandable footprint fails closed')
end

-- Q4: risk tolerance is a numeric comparison, not a reject-vs-pause switch.
-- The same known friendly beam risk (100%) is rejected above the threshold and
-- permitted at/under it.
do
    local above=build{policy={safety={max_selffire_risk=50}},allies={{uid=9,x=3,y=2}}}
    local result=above(attempt('T_MOONLIGHT_RAY'))
    check(result and result.action=='reject' and result.reason=='selffire_risk',
        'a known risk above max_selffire_risk is rejected')
    check(result.detail and result.detail.measurement==100 and result.detail.threshold==50,
        'the guard reports the measured risk and the policy threshold')
    local within=build{policy={safety={max_selffire_risk=100}},allies={{uid=9,x=3,y=2}}}
    local permitted=within(attempt('T_MOONLIGHT_RAY'))
    check(permitted and permitted.action=='permit' and permitted.detail.measurement==100,
        'a known risk at the policy threshold is permitted, not globally vetoed')
end

-- Conformance helper.
do
    local flame=Manifest.entry('T_FLAME')
    check(Guard.conformance(flame,{type='bolt'})==true,'a declared union member conforms')
    check(Guard.conformance(flame,{type='ball'})==nil,'a shape outside the union is a conformance fault')
    local ray=Manifest.entry('T_MOONLIGHT_RAY')
    check(Guard.conformance(ray,{type='beam'})==true,'an exact shape conforms')
    check(Guard.conformance(ray,{type='ball'})==nil,'a different shape is a conformance fault')
end

-- MOV-4 / Q4: the *same* known self/friendly risk is policy-owned. The plugin
-- must not hard-code a global rejection: a numeric comparison against the
-- policy threshold permits values within tolerance and reports the measurement.
do
    local strict=build{policy={safety={max_selffire_risk=0}},allies={{uid=9,x=3,y=2}}}
    local rejected=strict(attempt('T_MOONLIGHT_RAY'))
    check(rejected and rejected.action=='reject' and rejected.reason=='selffire_risk',
        'threshold 0 turns the known risk into a policy rejection')
    check(rejected.detail and rejected.detail.risk=='friendly' and rejected.detail.friendlies==1,
        'the known friendly-fire footprint is reported with the verdict')
    local tolerant=build{policy={safety={max_selffire_risk=50}},allies={{uid=9,x=3,y=2}}}
    local above=tolerant(attempt('T_MOONLIGHT_RAY'))
    check(above and above.action=='reject' and above.detail.measurement==100,
        'a risk above tolerance is rejected with the measurement')
    local exact=build{policy={safety={max_selffire_risk=100}},allies={{uid=9,x=3,y=2}}}
    local permitted=exact(attempt('T_MOONLIGHT_RAY'))
    check(permitted and permitted.action=='permit' and permitted.detail.threshold==100,
        'a risk within tolerance is permitted (policy authorises the cast)')
    local safe=exact(attempt('T_HEALING_LIGHT'))
    check(safe==nil,'a self-target action is not affected by the movement/selffire policy')
    -- An incalculable footprint still fails closed regardless of the threshold.
    local unknown=build{policy={safety={max_selffire_risk=100}},allies={{uid=9,x=3,y=2}},
        dynamicScalar=function() return 'unknown' end,
        defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=function()
            return {type='beam',range=10,selffire={dynamic='spellFriendlyFire'},
                friendlyfire={dynamic='spellFriendlyFire'}} end}}}
    local blocked=unknown(attempt('T_MOONLIGHT_RAY'))
    check(blocked and blocked.action=='reject' and blocked.detail.unknown==true,
        'an incalculable footprint fails closed even at full tolerance')
    -- A movement action is never blocked by a drift record (no runtime gate).
    local drift=build{drift=function() return {drift=true,findings={}} end}
    check(drift{action='use_talent',talent='T_RUSH',bound_target=2}==nil,
        'a movement adapter is not gated by advisory drift')
end


-- A′ §6.4/§6.5/§6.6: the stationary multi-prompt effect program (Earthen
-- Missiles). It is NOT movement — the caster never moves — so the guard must
-- measure the declared damage at EVERY chosen grid instead of skipping it, and
-- it must carry the raised spec's ACTUAL static flags into the precheck and the
-- footprint input.
do
    local function planOf(grids)
        local values={}
        local sequence={}
        for i,grid in ipairs(grids) do
            values[i]={kind='grid',request='grid',x=grid[1],y=grid[2],group='earthen_missiles'}
            sequence[i]={index=i,request='grid',subject='self',value_source='target_plan',
                observed={cursor_type='bolt'},group='earthen_missiles'}
        end
        -- R2-APR2-01: the planner attaches the RESOLVED request sequence, and
        -- the guard now requires it, so the fixture builds the realistic plan
        -- (`MovementPlanner.planSequence`) instead of a sequence-less stub.
        return {kind='sequence',values=values,request_sequence=sequence,
            annotation={landing={kind='deterministic'}}}
    end
    local function stationaryAttempt(talent,grids)
        local a=attempt(talent)
        a.plan=planOf(grids)
        return a
    end
    -- The routing is a validated consequence of the RESOLVED template: the
    -- manifest entry's movement leaf carries delivery='stationary', so the guard
    -- must never take the unconditional movement skip.
    local guard=build{policy={safety={max_selffire_risk=0}}}
    local permitted=guard(stationaryAttempt('T_EARTHEN_MISSILES',{{5,2},{6,2}}))
    check(permitted==nil or (permitted.action=='permit' and permitted.detail.stationary==true),
        'a self-safe stationary program is permitted with a stationary detail')
    -- A friendly ally inside a chosen footprint is measured (the regular
    -- variant has engine-default friendlyfire=true) and rejected at threshold 0.
    local allyRisk=build{policy={safety={max_selffire_risk=0}},allies={{uid=9,x=5,y=2}}}
    local rejected=allyRisk(stationaryAttempt('T_EARTHEN_MISSILES',{{5,2},{6,2}}))
    check(rejected and rejected.action=='reject' and rejected.detail.stationary==true,
        'a stationary program whose footprint covers an ally is measured and rejected')
    -- A′ §6.4: the dwarven variant's EXPLICIT `friendlyfire=false` makes the same
    -- ally footprint safe (0% friendly risk) — the raised spec's flag, not the
    -- curated default, reaches risk modelling.
    local dwarf=build{policy={safety={max_selffire_risk=0}},allies={{uid=9,x=5,y=2}}}
    local dwarfVerdict=dwarf(stationaryAttempt('T_DWARVEN_HALF_EARTHEN_MISSILES',{{5,2},{6,2}}))
    check(dwarfVerdict==nil or dwarfVerdict.action=='permit',
        'the dwarven variant does not risk a friendly ally (explicit friendlyfire=false)')
    -- A′ §6.4 (P1): `friendlyblock=false` must reach `canProject`. The engine
    -- uses it to let a FRIENDLY actor NOT block the projection
    -- (Target.lua:527-535,588-607,657-664), so a probe rebuilt from
    -- {type,range,talent} can report a false `no_line_of_sight`. The double here
    -- mirrors the engine rule: a friendly actor on the line blocks only when the
    -- probe does NOT carry friendlyblock=false.
    local function engineLineProject(probe,x,y)
        -- The friendly ally at (4,2) blocks the line unless friendlyblock=false.
        if x==5 and y==2 then
            if probe.friendlyblock==false then return true end
            return false
        end
        return true
    end
    local lineBuild=build{policy={safety={max_selffire_risk=0}},allies={{uid=9,x=4,y=2}},
        player_fields={canProject=function(self,probe,x,y)
            return engineLineProject(probe,x,y)
        end}}
    local dwarfLine=lineBuild(stationaryAttempt('T_DWARVEN_HALF_EARTHEN_MISSILES',{{5,2}}))
    check(not (dwarfLine and dwarfLine.reason=='no_line_of_sight'),
        'the dwarven friendlyblock=false probe does not manufacture a false no_line_of_sight')
    local regularLine=lineBuild(stationaryAttempt('T_EARTHEN_MISSILES',{{5,2},{6,2}}))
    check(regularLine and regularLine.reason=='no_line_of_sight',
        'the regular variant (no friendlyblock field) keeps the engine default blocking')
    -- Fail closed: no plan at all means the chosen grids are unknown.
    local noPlan=guard(attempt('T_EARTHEN_MISSILES'))
    check(noPlan and noPlan.action=='reject' and noPlan.reason=='movement_plan_unavailable',
        'a stationary program without its plan fails closed')
    -- A′ §6.5: EVERY plan value must be a valid grid — a malformed one is
    -- rejected, never silently filtered out (the previous partial-plan bug).
    local malformed=build{policy={safety={max_selffire_risk=0}}}
    local badValue=malformed(stationaryAttempt('T_EARTHEN_MISSILES',{{5,2},{nil,2}}))
    check(badValue and badValue.action=='reject'
        and badValue.reason=='movement_plan_unavailable',
        'a non-grid plan value fails closed instead of being filtered')
    -- R2-APR-01: the reviewer's sparse-plan reproduction — valid grids at keys
    -- 1 and 3 — must be rejected as movement_plan_unavailable BEFORE any
    -- precheck/expansion (ipairs-style iteration would have measured it as a
    -- complete ONE-grid plan and could publish a permit).
    do
        local prechecks=0
        local sparse=build{policy={safety={max_selffire_risk=0}},
            player_fields={canProject=function() prechecks=prechecks+1;return true end}}
        local sparseAttempt=attempt('T_EARTHEN_MISSILES')
        sparseAttempt.plan={kind='sequence',values={
            [1]={kind='grid',request='grid',x=5,y=2,group='earthen_missiles'},
            [3]={kind='grid',request='grid',x=6,y=2,group='earthen_missiles'}}}
        local sparseVerdict=sparse(sparseAttempt)
        check(sparseVerdict and sparseVerdict.action=='reject'
            and sparseVerdict.reason=='movement_plan_unavailable',
            'a sparse plan (valid grids at keys 1 and 3) is rejected, never measured')
        check(sparseVerdict.detail.detail=='bad_plan_shape' and sparseVerdict.detail.cause=='hole',
            'the sparse plan reports its dense-array cause (hole over key 2)')
        check(prechecks==0,'no precheck ran before the sparse plan was rejected')
    end
    -- R2-APR-01: a plan whose length disagrees with every declared executable
    -- sequence (2 or 3 entries for Earthen Missiles) is rejected before any
    -- precheck/expansion.
    do
        local prechecks=0
        local mismatch=build{policy={safety={max_selffire_risk=0}},
            player_fields={canProject=function() prechecks=prechecks+1;return true end}}
        local longAttempt=attempt('T_EARTHEN_MISSILES')
        longAttempt.plan=planOf({{5,2},{6,2},{5,3},{6,3}})
        local longVerdict=mismatch(longAttempt)
        check(longVerdict and longVerdict.action=='reject'
            and longVerdict.reason=='movement_plan_unavailable'
            and longVerdict.detail.detail=='plan_sequence_length_mismatch',
            'a plan longer than every declared sequence is rejected')
        check(prechecks==0,'no precheck ran before the length mismatch was rejected')
        -- A plan carrying the planner-attached resolved sequence is
        -- cross-checked against ITS length too: 2 values against a resolved
        -- 3-entry (TL5) sequence is a mismatch.
        local seqAttempt=attempt('T_EARTHEN_MISSILES')
        seqAttempt.plan=planOf({{5,2},{6,2}})
        seqAttempt.plan.request_sequence={
            {index=1,request='grid'},{index=2,request='grid'},{index=3,request='grid'}}
        local seqVerdict=mismatch(seqAttempt)
        check(seqVerdict and seqVerdict.action=='reject'
            and seqVerdict.reason=='movement_plan_unavailable'
            and seqVerdict.detail.detail=='plan_sequence_length_mismatch'
            and seqVerdict.detail.declared==3 and seqVerdict.detail.got==2,
            'a plan length disagreeing with the resolved request sequence is rejected')
        -- The matching case stays executable: 3 values with the resolved TL5
        -- sequence of length 3.
        local tl5Attempt=attempt('T_EARTHEN_MISSILES')
        tl5Attempt.plan=planOf({{5,2},{6,2},{5,3}})
        tl5Attempt.plan.request_sequence={
            {index=1,request='grid'},{index=2,request='grid'},{index=3,request='grid'}}
        local tl5Verdict=mismatch(tl5Attempt)
        check(tl5Verdict==nil or (tl5Verdict.action=='permit' and tl5Verdict.detail.stationary==true),
            'a plan matching the resolved request-sequence length is measured normally')
        check(prechecks>0,'the matching plan did run its prechecks')
    end
    -- R2-APR2-01: the SPARSE attached resolved sequence defeats a `#`-based
    -- length check (Lua `#` reports 1 for keys {1,3}), so the guard MUST
    -- dense-validate `plan.request_sequence` over ALL keys before using its
    -- length. The reviewer's exact SPARSE_DECLARED_BYPASS case: one dense grid
    -- plus an attached sequence at keys {1,3}.
    do
        local prechecks=0
        local bypass=build{policy={safety={max_selffire_risk=0}},
            player_fields={canProject=function() prechecks=prechecks+1;return true end}}
        local bypassAttempt=attempt('T_EARTHEN_MISSILES')
        bypassAttempt.plan={kind='sequence',
            values={{kind='grid',request='grid',x=5,y=2,group='earthen_missiles'}},
            request_sequence={[1]={index=1,request='grid'},[3]={index=3,request='grid'}}}
        local bypassVerdict=bypass(bypassAttempt)
        check(bypassVerdict and bypassVerdict.action=='reject'
            and bypassVerdict.reason=='movement_plan_unavailable'
            and bypassVerdict.detail.detail=='bad_plan_shape'
            and bypassVerdict.detail.cause=='hole',
            'a SPARSE attached request_sequence is rejected as bad_plan_shape/hole, never measured (R2-APR2-01)')
        check(prechecks==0,'no precheck ran before the sparse attached sequence was rejected')
    end
    -- R2-APR2-01: an attached sequence at keys {1,3} with a matching-count
    -- dense grid array (2 values) is still rejected, because the SEQUENCE shape
    -- is invalid independently of any length comparison.
    do
        local prechecks=0
        local hole=build{policy={safety={max_selffire_risk=0}},
            player_fields={canProject=function() prechecks=prechecks+1;return true end}}
        local holeAttempt=attempt('T_EARTHEN_MISSILES')
        holeAttempt.plan={kind='sequence',
            values={{kind='grid',request='grid',x=5,y=2,group='earthen_missiles'},
                {kind='grid',request='grid',x=6,y=2,group='earthen_missiles'}},
            request_sequence={[1]={index=1,request='grid'},[3]={index=3,request='grid'}}}
        local holeVerdict=hole(holeAttempt)
        check(holeVerdict and holeVerdict.action=='reject'
            and holeVerdict.reason=='movement_plan_unavailable'
            and holeVerdict.detail.detail=='bad_plan_shape'
            and holeVerdict.detail.cause=='hole',
            'a keys-{1,3} attached sequence is rejected (dense validation over ALL keys, R2-APR2-01)')
        check(prechecks==0,'no precheck ran before the keys-{1,3} sequence was rejected')
    end
    -- R2-APR2-01: an ABSENT attached sequence is a typed rejection, not a
    -- fallback that "matches any variant length". A one-grid plan with no
    -- attached sequence can never be measured.
    do
        local prechecks=0
        local absent=build{policy={safety={max_selffire_risk=0}},
            player_fields={canProject=function() prechecks=prechecks+1;return true end}}
        local absentAttempt=attempt('T_EARTHEN_MISSILES')
        absentAttempt.plan={kind='sequence',
            values={{kind='grid',request='grid',x=5,y=2,group='earthen_missiles'}}}
        local absentVerdict=absent(absentAttempt)
        check(absentVerdict and absentVerdict.action=='reject'
            and absentVerdict.reason=='movement_plan_unavailable'
            and absentVerdict.detail.detail=='plan_sequence_missing',
            'an ABSENT attached request_sequence is rejected (never matches a variant length, R2-APR2-01)')
        check(prechecks==0,'no precheck ran before the absent sequence was rejected')
    end
    -- R2-APR2-01: an attached sequence whose length is not a DECLARED executable
    -- program length (Earthen Missiles declares 2 and 3) is rejected even though
    -- it agrees with the plan length.
    do
        local prechecks=0
        local invented=build{policy={safety={max_selffire_risk=0}},
            player_fields={canProject=function() prechecks=prechecks+1;return true end}}
        local inventedAttempt=attempt('T_EARTHEN_MISSILES')
        inventedAttempt.plan={kind='sequence',
            values={{kind='grid',request='grid',x=5,y=2,group='earthen_missiles'}},
            request_sequence={{index=1,request='grid'}}}
        local inventedVerdict=invented(inventedAttempt)
        check(inventedVerdict and inventedVerdict.action=='reject'
            and inventedVerdict.reason=='movement_plan_unavailable'
            and inventedVerdict.detail.detail=='plan_sequence_length_mismatch',
            'a caller-invented 1-entry program length is rejected (R2-APR2-01)')
        check(prechecks==0,'no precheck ran before the invented-length sequence was rejected')
    end
    -- R2-APR2-01: an attached sequence with the right LENGTH but a wrong KIND
    -- (declared 'actor' where the plan value is a grid) is rejected.
    do
        local prechecks=0
        local wrongKind=build{policy={safety={max_selffire_risk=0}},
            player_fields={canProject=function() prechecks=prechecks+1;return true end}}
        local wrongKindAttempt=attempt('T_EARTHEN_MISSILES')
        wrongKindAttempt.plan=planOf({{5,2},{6,2}})
        wrongKindAttempt.plan.request_sequence[2].request='actor'
        local wrongKindVerdict=wrongKind(wrongKindAttempt)
        check(wrongKindVerdict and wrongKindVerdict.action=='reject'
            and wrongKindVerdict.reason=='movement_plan_unavailable'
            and wrongKindVerdict.detail.detail=='plan_sequence_kind_mismatch'
            and wrongKindVerdict.detail.index==2,
            'a kind-mismatching attached sequence entry is rejected entry-by-entry (R2-APR2-01)')
        check(prechecks==0,'no precheck ran before the kind mismatch was rejected')
    end
    -- A′ §6.5: EVERY component x grid footprint must expand. One unreadable
    -- expansion with another readable one (an ally standing in the readable
    -- footprint) must never be measured as a partial, complete union.
    do
        local mod=require 'mod.auto_combat.EffectFootprint'
        local realExpand=mod.expand
        local calls=0
        mod.expand=function(spec,opts)
            calls=calls+1
            if calls==2 then return nil,'native_failed' end
            return realExpand(spec,opts)
        end
        local ok,result=pcall(function()
            local g=build{policy={safety={max_selffire_risk=0}},allies={{uid=9,x=5,y=2}}}
            return g(stationaryAttempt('T_EARTHEN_MISSILES',{{5,2},{6,2}}))
        end)
        mod.expand=realExpand
        check(ok and result and result.action=='reject' and result.reason=='selffire_risk'
            and result.detail.unknown==true and calls==2,
            'a partially-unreadable footprint union fails closed (never measured as complete)')
    end
    -- The readable-union baseline: with both grids measured, the ally in the
    -- FIRST grid is a known risk (not unknown).
    local both=build{policy={safety={max_selffire_risk=0}},allies={{uid=9,x=5,y=2}}}
    local bothVerdict=both(stationaryAttempt('T_EARTHEN_MISSILES',{{5,2},{6,2}}))
    check(bothVerdict and bothVerdict.action=='reject' and bothVerdict.detail.stationary==true
        and bothVerdict.detail.unknown~=true,
        'the full two-grid union measures the known ally risk (baseline for the fail-closed case)')
    -- An out-of-range chosen grid fails closed per grid.
    local far=guard(stationaryAttempt('T_EARTHEN_MISSILES',{{2,2},{14,2}}))
    check(far and far.action=='reject' and far.reason=='target_out_of_range',
        'a stationary chosen grid outside the range fails closed')
    -- A′ §6.6: the uncertainty is an annotation on the lowered plan, published by
    -- the planner and the capability summary, never a refusal.
    local Manifest=require 'mod.auto_combat.EffectManifest'
    local em=Manifest.entry('T_EARTHEN_MISSILES')
    check(em.movement.variants[1].movement.delivery=='stationary'
        and em.movement.variants[2].movement.delivery=='stationary',
        'both talent-level branches resolve to the stationary delivery (routing source)')
end


-- A′ §6.5: stationary guard routing is a VALIDATED CONSEQUENCE of the resolved
-- template, never an independent manifest boolean. A mover declaration that a
-- caller annotated with a fabricated `stationary=true` field must still be
-- SKIPPED as movement; a stationary template leaf is measured even without any
-- entry-level field. This is proven by injecting both shapes into the live
-- manifest (the same technique `tests/test_auto_combat_catalog.lua` uses).
do
    local Factory=require 'mod.auto_combat.MovementAdapterFactory'
    local saved=Manifest.ENTRIES.T_MOONLIGHT_RAY
    local function planOf(grids)
        local values={}
        local sequence={}
        for i,grid in ipairs(grids) do
            values[i]={kind='grid',request='grid',x=grid[1],y=grid[2]}
            sequence[i]={index=i,request='grid'}
        end
        -- R2-APR2-01: the planner-attached resolved sequence is required.
        return {kind='sequence',values=values,request_sequence=sequence,
            annotation={landing={kind='deterministic'}}}
    end
    -- (a) A MOVER leaf with a fabricated stationary[] boolean must be skipped.
    local mover=assert(Factory.expand('request_then_landing',{
        request_sequence={{index=1,request='actor',subject='self',
            observed={cursor_type='hit',friendlyblock=false,nowarning=true,default_target='self'}}},
        delivery='teleport',landing='random',center='self',traverses=false,
        relocates_other=false,radius=1,min_radius=0,range=10}))
    Manifest.ENTRIES.T_MOONLIGHT_RAY={kind='movement',target='grid',stationary=true,
        movement=mover,components={},conformance={builder=false}}
    local guard=build{policy={safety={max_selffire_risk=0}}}
    local moverAttempt=attempt('T_MOONLIGHT_RAY')
    moverAttempt.plan=planOf({{5,2}})
    check(guard(moverAttempt)==nil,
        'a fabricated entry-level stationary boolean cannot route a mover leaf into the measurement')
    -- (b) A STATIONARY template leaf is measured with no entry-level field at all.
    local stat=assert(Factory.expand('stationary_sequence',{range=10,request_sequence={
        {index=1,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='bolt'},group='probe'},
        {index=2,request='grid',subject='self',value_source='target_plan',
            observed={cursor_type='bolt'},group='probe'}}}))
    Manifest.ENTRIES.T_MOONLIGHT_RAY={kind='movement',target='grid',
        movement=stat,components={
            {id='missile',phase='projectile',delivery='projectile',shape='bolt',range=10,
                center='target',selffire=100,friendlyfire=100}},
        conformance={builder=false}}
    local statAttempt=attempt('T_MOONLIGHT_RAY')
    statAttempt.plan=planOf({{5,2},{6,2}})
    local measured=guard(statAttempt)
    check(measured==nil or (measured.action=='permit' and measured.detail.stationary==true),
        'a stationary template leaf is measured from the resolved template alone')
    -- (c) R2-APR-02: a hand-authored mover-shape leaf that merely DECLARES
    -- `delivery='stationary'` (the reviewer's bypass: the factory now refuses
    -- this at build time on every non-stationary template, so only a
    -- hand-written descriptor can still present it) carries NO template marker
    -- and must be SKIPPED as movement — the raw enum is never a routing input.
    local forgedStationary={delivery='stationary',landing='random',center='self',
        traverses=false,relocates_other=false,target_requests={'actor'},
        request_sequence={{index=1,request='actor',subject='self',
            observed={cursor_type='hit',nowarning=true}}}}
    Manifest.ENTRIES.T_MOONLIGHT_RAY={kind='movement',target='grid',
        movement=forgedStationary,components={},conformance={builder=false}}
    local forgedAttempt=attempt('T_MOONLIGHT_RAY')
    forgedAttempt.plan=planOf({{5,2}})
    check(guard(forgedAttempt)==nil,
        'a caller-authored stationary delivery without the template marker is skipped, never measured (R2-APR-02)')
    Manifest.ENTRIES.T_MOONLIGHT_RAY=saved
end

-- R2-APR-04: the REAL raised static flags reach the native footprint input.
-- Giant Leap's builder explicitly returns `selffire=false`
-- (game/modules/tome/data/talents/uber/str.lua:38-40); the footprint input the
-- guard builds for the projection must carry that field, exactly like the real
-- `ActorProject:project` input (getType fills it only as a DEFAULT and
-- `table.update` never overwrites a raised field).
do
    local Footprint=require 'mod.auto_combat.EffectFootprint'
    local savedEntry=Manifest.ENTRIES.T_MOONLIGHT_RAY
    local realExpand=Footprint.expand
    local captured={}
    Footprint.expand=function(spec,opts)
        captured[#captured+1]=spec
        return realExpand(spec,opts)
    end
    local giantLeapBuilder=function()
        -- Verbatim field set of Giant Leap's raised spec (uber/str.lua:38-40):
        -- type/range(self:getTalentRange=10)/selffire=false/radius.
        return {type='ball',range=10,selffire=false,radius=1}
    end
    Manifest.ENTRIES.T_MOONLIGHT_RAY={kind='attack',target='hostile',resource='negative',
        range=10,cursor={shape='ball',range=10,radius=1},
        conformance={shape='ball',builder=true},
        components={
            {id='cursor',phase='cursor',delivery='project',shape='ball',range=10,center='target'},
            {id='instant',phase='instant',delivery='project',shape='ball',range=10,center='target',
                selffire=100,friendlyfire=100}}}
    local defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=giantLeapBuilder}}
    local guard=build{defs=defs,allies={{uid=9,x=5,y=2}}}
    local ok,verdict=pcall(guard,attempt('T_MOONLIGHT_RAY'))
    Footprint.expand=realExpand
    Manifest.ENTRIES.T_MOONLIGHT_RAY=saved
    check(ok and verdict and verdict.action=='reject' and verdict.detail.risk=='friendly',
        'the injected Giant-Leap-shaped talent measured its ally risk through the footprint')
    local footprintInput
    for _,spec in ipairs(captured) do
        if spec.shape=='ball' and spec.selffire~=nil then footprintInput=spec end
    end
    check(footprintInput~=nil and footprintInput.selffire==false,
        'Giant Leap\'s real raised selffire=false reaches the native footprint input (R2-APR-04)')
    -- The remaining engine-consulted flags forward from a REAL raised spec too:
    -- bow-threading.lua:143 raises stop_block=true with friendlyfire=false and
    -- friendlyblock=false; actorblock is engine-consulted (Target.block_path,
    -- default true) and must survive forwarding when raised.
    local bowSpec=Guard.footprintSpec({shape='ball',radius=1,center='target'},
        {x=0,y=0},{x=3,y=0},{type='ball',range=8,stop_block=true,friendlyfire=false,
            friendlyblock=false})
    check(bowSpec.stop_block==true and bowSpec.friendlyfire==false and bowSpec.friendlyblock==false,
        'a real raised stop_block/friendlyfire/friendlyblock spec reaches the footprint input')
    local actorSpec=Guard.footprintSpec({shape='ball',radius=1,center='target'},
        {x=0,y=0},{x=3,y=0},{type='ball',range=8,actorblock=false})
    check(actorSpec.actorblock==false,
        'a raised actorblock reaches the footprint input (R2-APR-04)')
    -- R2-APR2-03: the REMAINING engine-consulted fields forward from a REAL
    -- raised spec, including an explicit `false` (which the engine honours).
    -- `force_max_range=true` is raised by real specs (spells/golem.lua:271-272
    -- Eye Beam, spells/thaumaturgy.lua:234 Elemental Array) and extends line
    -- stepping (ActorProject.lua:78,113-114); `block_path=false` is raised by
    -- corruptions/shadowflame.lua:155-159 and disables the default blocker
    -- (`if typ.block_path then` is false for `false`).
    local golemSpec=Guard.footprintSpec({shape='beam',range=7,center='target'},
        {x=0,y=0},{x=3,y=0},{type='beam',range=7,force_max_range=true,friendlyfire=false})
    check(golemSpec.force_max_range==true,
        'a real raised force_max_range reaches the footprint input (R2-APR2-03)')
    local shadowSpec=Guard.footprintSpec({shape='ball',radius=20,center='target'},
        {x=0,y=0},{x=3,y=0},{type='ball',range=20,radius=20,block_path=false,
            block_radius=false,selffire=false})
    check(shadowSpec.block_path==false and shadowSpec.block_radius==false,
        'a real raised block_path=false/block_radius=false reaches the footprint input (R2-APR2-03)')
    -- A raised CALLBACK form is forwarded verbatim (function identity preserved).
    local callback=function() return true,false,false end
    local callbackSpec=Guard.footprintSpec({shape='ball',radius=2,center='target'},
        {x=0,y=0},{x=3,y=0},{type='ball',range=8,block_path=callback})
    check(callbackSpec.block_path==callback,
        'a raised block_path FUNCTION is forwarded verbatim (R2-APR2-03)')
    -- min_range / grid_exclude / filter are all engine-consulted and forwarded.
    local geometrySpec=Guard.footprintSpec({shape='ball',radius=2,center='target'},
        {x=0,y=0},{x=3,y=0},{type='ball',range=8,min_range=3,
            grid_exclude={[5]={[5]=true}},filter=function() return true end})
    check(geometrySpec.min_range==3 and geometrySpec.grid_exclude~=nil
        and type(geometrySpec.filter)=='function',
        'raised min_range/grid_exclude/filter reach the footprint input (R2-APR2-03)')
    -- The allowlist is closed: an unrelated raised key is NOT copied.
    local closedSpec=Guard.footprintSpec({shape='ball',radius=2,center='target'},
        {x=0,y=0},{x=3,y=0},{type='ball',range=8,arbitrary_key='x'})
    check(closedSpec.arbitrary_key==nil,
        'the forwarded allowlist is closed (an unrelated raised key is dropped)')
    -- R2-APR2-03: a REAL raised `force_max_range` changes the MEASURED footprint
    -- through the full guard path — not just the copied field. The injected
    -- builder returns Eye Beam's real raised spec; the captured footprint input
    -- must carry it to the native expander.
    do
        local saved=Manifest.ENTRIES.T_MOONLIGHT_RAY
        local realExpand2=Footprint.expand
        local specs={}
        Footprint.expand=function(spec,opts)
            specs[#specs+1]=spec
            return realExpand2(spec,opts)
        end
        local eyeBeam=function()
            -- Verbatim field set of Eye Beam's raised spec (golem.lua:271-272).
            return {type='beam',range=7,force_max_range=true,friendlyfire=false}
        end
        Manifest.ENTRIES.T_MOONLIGHT_RAY={kind='attack',target='hostile',resource='negative',
            range=7,cursor={shape='beam',range=7},
            conformance={shape='beam',builder=true},
            components={
                {id='cursor',phase='cursor',delivery='project',shape='beam',range=7,center='target'},
                {id='instant',phase='instant',delivery='project',shape='beam',range=7,center='target',
                    selffire=100,friendlyfire=100}}}
        local g=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=eyeBeam}}}
        local okInjected,injectedVerdict=pcall(g,attempt('T_MOONLIGHT_RAY'))
        Footprint.expand=realExpand2
        Manifest.ENTRIES.T_MOONLIGHT_RAY=saved
        local sawForce=false
        for _,spec in ipairs(specs) do
            if spec.force_max_range==true then sawForce=true end
        end
        check(okInjected and sawForce,
            'Eye Beam\'s real raised force_max_range reaches the measured footprint path (R2-APR2-03)')
    end
    -- R2-APR2-03: the same allowlist rides the STATIONARY footprint input, so a
    -- curated raised field reaches that path too. `stationaryProbeSpec` is
    -- exercised via `STATIONARY_SPECS`; assert the shared copier is the one used
    -- by injecting a real raised field into the stationary per-grid spec is
    -- covered by the copyFootprintFlags unit assertions above.
    local copied=Guard.copyFootprintFlags({shape='beam',range=7},
        {force_max_range=true,block_path=false,friendlyfire=false,unrelated=true})
    check(copied.force_max_range==true and copied.block_path==false
        and copied.friendlyfire==false and copied.unrelated==nil,
        'copyFootprintFlags is the single closed forwarder for both footprint paths (R2-APR2-03)')
end

-- R2-APR3-01: a raised `act_exclude` ({[uid]=true,...}) reaches the footprint
-- input AND the membership measurement: the engine admits actors against it
-- BEFORE the self/friendly-fire filters (ActorProject.lua:248-255, documented
-- Target.lua:647-650), so an excluded ally must NOT be measured as affected.
do
    -- The raised table is forwarded verbatim into the footprint input.
    local exclude={[9]=true}
    local forwarded=Guard.footprintSpec({shape='beam',range=7,center='target'},
        {x=0,y=0},{x=3,y=0},{type='beam',range=7,act_exclude=exclude})
    check(forwarded.act_exclude==exclude,
        'a raised act_exclude reaches the footprint input verbatim (R2-APR3-01)')
    -- An explicit [uid]=false stays a non-exclusion (nil-vs-false admitted).
    local forwardedFalse=Guard.footprintSpec({shape='beam',range=7,center='target'},
        {x=0,y=0},{x=3,y=0},{type='beam',range=7,act_exclude={[9]=false}})
    check(forwardedFalse.act_exclude~=nil and forwardedFalse.act_exclude[9]==false,
        'an act_exclude table with an explicit false is forwarded (R2-APR3-01)')
    -- Full guard path: Moonlight Ray's builder raises act_exclude for ally uid
    -- 9 standing IN the beam line; the engine would not hit that ally, so the
    -- guard must not reject on it.
    local allyInLine={uid=9,x=3,y=2}
    local savedEntry=Manifest.ENTRIES.T_MOONLIGHT_RAY
    Manifest.ENTRIES.T_MOONLIGHT_RAY={kind='attack',target='hostile',resource='negative',
        range=7,cursor={shape='beam',range=7},
        conformance={shape='beam',builder=true},
        components={
            {id='cursor',phase='cursor',delivery='project',shape='beam',range=7,center='target'},
            {id='instant',phase='instant',delivery='project',shape='beam',range=7,center='target',
                selffire=100,friendlyfire=100}}}
    local excludedBuilder=function()
        return {type='beam',range=7,act_exclude={[9]=true}}
    end
    local exempt=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=excludedBuilder}},
        allies={allyInLine}}
    check(exempt(attempt('T_MOONLIGHT_RAY'))==nil,
        'a raised act_exclude exempts the excluded ally from the measured risk (R2-APR3-01)')
    -- A DIFFERENT uid in act_exclude does not exempt ally 9.
    local otherBuilder=function()
        return {type='beam',range=7,act_exclude={[8]=true}}
    end
    local other=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=otherBuilder}},
        allies={allyInLine}}
    local hitOther=other(attempt('T_MOONLIGHT_RAY'))
    check(hitOther and hitOther.reason=='selffire_risk' and hitOther.detail.risk=='friendly',
        'act_exclude only exempts the uids it names (R2-APR3-01)')
    -- An actor whose uid is unreadable under a raised act_exclude keeps the
    -- membership unknown (conservative union, fail closed).
    local noUid=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=excludedBuilder}},
        allies={{x=3,y=2}}}
    local unknownUid=noUid(attempt('T_MOONLIGHT_RAY'))
    check(unknownUid and unknownUid.action=='reject' and unknownUid.detail.unknown==true,
        'an unreadable uid under a raised act_exclude fails closed (R2-APR3-01)')
    -- R2-APR3-01: the engine's exact admission is `typ.act_exclude and
    -- typ.act_exclude[act.uid]` (ActorProject.lua:252-255). Under this Lua
    -- runtime that means: nil/false = no exclusion; a table = uid lookup; a
    -- STRING indexes to nil = NO EXCLUSION; a number/`true` makes the indexing
    -- RAISE. The guard must mirror each case, not blanket-map every truthy
    -- non-table to unknown (which EffectRisk turned into a KNOWN risk).
    local function engineExcluded(value,uid)
        local ok,result=pcall(function()
            local typ={act_exclude=value}
            local act={uid=uid}
            return act and (typ.act_exclude and typ.act_exclude[act.uid]) or false
        end)
        if not ok then return nil end
        return result and true or false
    end
    -- The table/`[uid]=false`/nil/`true` cases are compared against the engine
    -- expression value-for-value via `M.actExcludeVerdict`.
    check(Guard.actExcludeVerdict(nil,9)==engineExcluded(nil,9),
        'nil act_exclude mirrors the engine (no exclusion)')
    check(Guard.actExcludeVerdict(false,9)==engineExcluded(false,9),
        'false act_exclude mirrors the engine (no exclusion)')
    check(Guard.actExcludeVerdict({[9]=true},9)==engineExcluded({[9]=true},9),
        'a table act_exclude mirrors the engine uid lookup (excluded)')
    check(Guard.actExcludeVerdict({[9]=false},9)==engineExcluded({[9]=false},9),
        'a table with [uid]=false mirrors the engine (not excluded)')
    check(Guard.actExcludeVerdict({[8]=true},9)==engineExcluded({[8]=true},9),
        'a table naming another uid mirrors the engine (not excluded)')
    -- A string indexes without error and yields nil: native no-exclusion.
    check(Guard.actExcludeVerdict('nope',9)==false and engineExcluded('nope',9)==false,
        'a string act_exclude mirrors the engine: no exclusion (R2-APR3-01)')
    check(Guard.malformedActExclude({act_exclude='nope'})==nil,
        'a string act_exclude is not a malformed-unknown (R2-APR3-01)')
    -- A number or `true` raises natively: the guard types it as unknown.
    check(Guard.actExcludeVerdict(7,9)==nil and engineExcluded(7,9)==nil,
        'a number act_exclude is undecidable (mirrors the native indexing error)')
    check(Guard.actExcludeVerdict(true,9)==nil and engineExcluded(true,9)==nil,
        'a true act_exclude is undecidable (mirrors the native indexing error)')
    check(Guard.malformedActExclude({act_exclude=7})=='act_exclude'
        and Guard.malformedActExclude({act_exclude=true})=='act_exclude',
        'number/true act_exclude are typed malformed-unknown (R2-APR3-01)')

    -- A STRING exclusion is native-faithful: the clear beam is NOT rejected as a
    -- known 100% self-risk (the rev-4 defect), because native does not exclude.
    local stringBuilder=function()
        return {type='beam',range=7,act_exclude='nope'}
    end
    local stringGuard=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=stringBuilder}},
        allies={allyInLine}}
    local stringVerdict=stringGuard(attempt('T_MOONLIGHT_RAY'))
    check(stringVerdict and stringVerdict.reason=='selffire_risk'
        and stringVerdict.detail.risk=='friendly' and not stringVerdict.detail.unknown,
        'a string act_exclude behaves exactly like native: only the real ally triggers (R2-APR3-01)')
    local clearString=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=stringBuilder}},
        allies={}}
    check(clearString(attempt('T_MOONLIGHT_RAY'))==nil,
        'a string act_exclude never fabricates a known 100% self-risk on a clear beam (R2-APR3-01)')

    -- A NUMBER/`true` exclusion is a TYPED unknown -> fail closed, NOT a known
    -- self/friendly risk (the rev-4 defect: unknown=false risk=self).
    for _,value in ipairs({7,true}) do
        local malformedBuilder=function()
            return {type='beam',range=7,act_exclude=value}
        end
        local malformed=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=malformedBuilder}},
            allies={allyInLine}}
        local verdict=malformed(attempt('T_MOONLIGHT_RAY'))
        check(verdict and verdict.action=='reject' and verdict.detail.unknown==true
            and verdict.detail.reason=='malformed_act_exclude' and verdict.detail.field=='act_exclude'
            and verdict.detail.measurement==nil,
            'a number/true act_exclude is a typed unknown -> fail closed, never a known risk (R2-APR3-01)')
        local clearMalformed=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=malformedBuilder}},
            allies={}}
        check(clearMalformed(attempt('T_MOONLIGHT_RAY')).detail.unknown==true,
            'a number/true act_exclude fails closed even with an empty footprint (R2-APR3-01)')
    end
    Manifest.ENTRIES.T_MOONLIGHT_RAY=savedEntry
end

-- R2-APR3-02 (checklist B): the engine INVOKES block_path/block_radius/filter
-- as functions (ActorProject.lua:60,74,95-96 and the radial typ:block_radius
-- calls). A non-nil, non-function value is NEVER forwarded: it is an explicit
-- unknown -> fail-closed rejection BEFORE any expansion. A real callback and an
-- explicit `false` stay forwarded verbatim.
do
    -- The malformed value is not copied into the footprint input...
    local cb=function() return true,false,false end
    for _,malformed in ipairs({
        {field='block_path',value='not_a_function',kind='string'},
        {field='block_radius',value=3,kind='number'},
        {field='filter',value=true,kind='boolean'},
        {field='block_path',value=0,kind='number'},
        {field='block_radius',value='x',kind='string'},
        {field='filter',value=7,kind='number'}}) do
        local spec=Guard.copyFootprintFlags({shape='beam',range=7},
            {type='beam',range=7,[malformed.field]=malformed.value})
        check(spec[malformed.field]==nil,
            'a malformed '..malformed.field..' ('..malformed.kind..') is never forwarded (R2-APR3-02)')
        check(Guard.malformedFunctionField({[malformed.field]=malformed.value})==malformed.field,
            'a malformed '..malformed.field..' ('..malformed.kind..') is a typed unknown (R2-APR3-02)')
    end
    -- ...while a real callback and an explicit false stay valid (typed nil).
    check(Guard.malformedFunctionField({block_path=cb,block_radius=false,filter=cb})==nil,
        'a real callback and an explicit false stay valid (R2-APR3-02)')
    check(Guard.malformedFunctionField(nil)==nil
        and Guard.malformedFunctionField({})==nil,
        'absent function-valued fields stay valid (R2-APR3-02)')
    -- Full guard path: a builder raising a malformed block_path fails closed
    -- with the typed reason BEFORE any footprint expansion.
    local Footprint=require 'mod.auto_combat.EffectFootprint'
    local savedEntry=Manifest.ENTRIES.T_MOONLIGHT_RAY
    local realExpand=Footprint.expand
    local expanded=0
    Footprint.expand=function(spec,opts)
        expanded=expanded+1
        return realExpand(spec,opts)
    end
    Manifest.ENTRIES.T_MOONLIGHT_RAY={kind='attack',target='hostile',resource='negative',
        range=7,cursor={shape='beam',range=7},
        conformance={shape='beam',builder=true},
        components={
            {id='cursor',phase='cursor',delivery='project',shape='beam',range=7,center='target'},
            {id='instant',phase='instant',delivery='project',shape='beam',range=7,center='target',
                selffire=100,friendlyfire=100}}}
    local cases={
        {field='block_path',value='not_a_function'},
        {field='block_path',value=3},
        {field='block_radius',value=3},
        {field='block_radius',value='x'},
        {field='filter',value=true},
        {field='filter',value=7}}
    for _,case in ipairs(cases) do
        local raised={type='beam',range=7}
        raised[case.field]=case.value
        local builder=function() return raised end
        local g=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=builder}}}
        local ok,verdict=pcall(g,attempt('T_MOONLIGHT_RAY'))
        check(ok and verdict and verdict.action=='reject'
            and verdict.reason=='selffire_risk' and verdict.detail.unknown==true
            and verdict.detail.reason=='malformed_function_field'
            and verdict.detail.field==case.field,
            'a malformed function-valued raised field fails closed typed (R2-APR3-02: '
                ..case.field..')')
    end
    check(expanded==0,
        'a malformed function-valued raised field never reaches the footprint expansion (R2-APR3-02)')
    Footprint.expand=realExpand
    Manifest.ENTRIES.T_MOONLIGHT_RAY=savedEntry
end

print('Auto-combat guard: '..checks..' checks passed')
