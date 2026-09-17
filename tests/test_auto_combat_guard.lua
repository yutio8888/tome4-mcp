-- V2-2: the manifest-driven guard composes canonical components, resolves
-- variants from audited scalar reads and applies the D2 policy.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
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
        drift=opts.drift or function() return true end,
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
    local guard=build{drift=function() return nil,'adapter_source_drift','hash' end}
    local result=guard(attempt('T_MOONLIGHT_RAY'))
    check(result and result.reason=='adapter_source_drift' and result.action=='reject',
        'a source drift rejects under max_selffire_risk=0')
    local soft=build{drift=function() return nil,'adapter_source_drift','hash' end,
        policy={safety={max_selffire_risk=50}}}
    local paused=soft(attempt('T_MOONLIGHT_RAY'))
    check(paused and paused.action=='pause','a source drift pauses when risk tolerance is non-zero')
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

-- V2-REV-02: builder invocation failure is a compatibility fault, not a reason
-- to fall back to stale manifest geometry; self-target actions are not exempt
-- from drift.
do
    local throwing=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=function() error('boom') end}}}
    local first=throwing(attempt('T_MOONLIGHT_RAY'))
    check(first and first.reason=='adapter_builder_failed','a throwing builder fails closed')
    local nonTable=build{defs={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',target=function() return 'nope' end}}}
    local second=nonTable(attempt('T_MOONLIGHT_RAY'))
    check(second and second.reason=='adapter_builder_failed','a non-table builder fails closed')
    local drifted=build{drift=function() return nil,'adapter_source_drift','hash' end}
    local third=drifted(attempt('T_HEAL'))
    check(third and third.reason=='adapter_source_drift','a self-target action is not exempt from drift')
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

-- D2: risk tolerance only chooses reject vs pause, never authorises a cast.
do
    local guard=build{policy={safety={max_selffire_risk=50}},allies={{uid=9,x=3,y=2}}}
    local result=guard(attempt('T_MOONLIGHT_RAY'))
    check(result and result.action=='pause' and result.reason=='selffire_risk',
        'max_selffire_risk>0 pauses rather than casting')
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

print('Auto-combat guard: '..checks..' checks passed')
