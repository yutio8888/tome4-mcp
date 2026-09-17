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
            if conformance and conformance.builder then
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

-- V2-REV-04: the player projectile opt-in is composed by the guard.
do
    local function flameBuild(allow)
        local defs={T_FLAME={id='T_FLAME',target=function()
            return {type='ball',range=10,radius=5,selffire=true,friendlyfire=true} end}}
        local guard=build{defs=defs,talentLevel=function() return 1 end,
            player_fields={allow_player_selffire=allow}}
        return guard(attempt('T_FLAME'))
    end
    local optedIn=flameBuild(true)
    check(optedIn and optedIn.reason=='selffire_risk',
        'a player projectile with the opt-in is a self risk')
    check(flameBuild(false)==nil,'a player projectile without the opt-in suppresses the self-hit')
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
