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
        for i,grid in ipairs(grids) do
            values[i]={kind='grid',request='grid',x=grid[1],y=grid[2],group='earthen_missiles'}
        end
        return {kind='sequence',values=values,annotation={landing={kind='deterministic'}}}
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
        for i,grid in ipairs(grids) do
            values[i]={kind='grid',request='grid',x=grid[1],y=grid[2]}
        end
        return {kind='sequence',values=values,annotation={landing={kind='deterministic'}}}
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
end

print('Auto-combat guard: '..checks..' checks passed')
