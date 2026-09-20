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
local Factory=require 'mod.auto_combat.MovementAdapterFactory'
local Footprint=require 'mod.auto_combat.EffectFootprint'
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
        known=opts.known or function() return true end,
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

-- S3 S-U2 (REAL_SHADOWSTEP_TG, cunning/shadow-magic.lua:123): the mixed entry
-- enumerates the radius-5 candidate set; a landing_adjacent condition is
-- resolved PER CANDIDATE (adjacent activates, non-adjacent does not); an
-- unreadable anchor propagates unknown; a direct component is evidenced without
-- any footprint expansion.
do
    local Fixtures=assert(loadfile(root..'/tests/s3_real_specs.lua'))()
    local fixture=Fixtures.REAL_SHADOWSTEP_TG
    local copy=fixture.build()
    Fixtures.assertFields(fixture,copy,'S-U2 shadowstep spec copy')
    Fixtures.assertRawPresence(fixture,copy,'S-U2 shadowstep spec copy')
    local function specBuild()
        return {type=copy.type,range=copy.range,talent=copy.talent}
    end
    local guard=build{defs={T_SHADOWSTEP={target=specBuild}},policy={safety={max_selffire_risk=0}}}
    local verdict=guard(attempt('T_SHADOWSTEP'))
    check(verdict~=nil and verdict.action=='permit',
        'a mixed movement entry is no longer skipped (S-U3), it evaluates to a permit')
    local detail=verdict and verdict.detail or {}
    check(detail.candidate_count==80,
        'the no-plan descriptor envelope is the radius-5 candidate set around the bound actor '
        ..'(80 in-bounds cells on the 10x10 fixture map)',detail.candidate_count)
    check(detail.components_evaluated==2 and detail.threshold==0,
        'both direct components are evaluated against the zero threshold')
    -- Pure movement still skips; mixed movement does not (S-U3).
    check(guard({action='use_talent',talent='T_RUSH',bound_target=2})==nil,
        'a pure movement entry still skips the guard (S-U3)')
    -- Candidate-condition semantics (pure, exported for tests; called after a
    -- build so the build-time assignment is live).
    local Condition=Guard.candidateCondition
    local candidates=Guard.landingCandidates(nil,Manifest.entry('T_SHADOWSTEP'),
        {x=2,y=2},{x=5,y=2},{w=10,h=10})
    check(candidates~=nil and candidates.kind=='bounded' and candidates.radius==5
        and candidates.center.x==5 and candidates.center.y==2,
        'the exported candidate set is the bounded radius-5 circle around the bound actor')
    local orderOk=true
    for i=2,#candidates.cells do
        if candidates.cells[i-1].y>candidates.cells[i].y
            or (candidates.cells[i-1].y==candidates.cells[i].y
                and candidates.cells[i-1].x>candidates.cells[i].x) then
            orderOk=false
        end
    end
    check(orderOk,'the candidate enumeration is in deterministic (y,x) order')
    check(Condition({kind='landing_adjacent',anchor='actor'},{x=6,y=2},{x=5,y=2})==true,
        'an adjacent candidate satisfies landing_adjacent (actor anchor)')
    check(Condition({kind='landing_adjacent',anchor='actor'},{x=9,y=2},{x=5,y=2})==false,
        'a non-adjacent candidate does NOT satisfy landing_adjacent')
    check(Condition({kind='landing_adjacent',anchor='actor'},{x=6,y=2},nil)=='unknown'
        or Condition({kind='landing_adjacent',anchor='actor'},{x=6,y=2},{})=='unknown',
        'an unreadable anchor is unknown, never silently false')
    check(Condition(nil,{x=6,y=2},{x=5,y=2})==true,
        'an always/absent condition holds for every candidate')
    -- Unknown anchor propagates to the component resolution.
    local unknownGuard=build{defs={T_SHADOWSTEP={target=specBuild}},policy={safety={max_selffire_risk=0}}}
    check(unknownGuard(attempt('T_SHADOWSTEP'))~=nil,
        'a readable anchor keeps the action permitted')
    -- Landing envelope unavailable: a radius that cannot be read fails closed
    -- (negative evidence requirement: unreadable radius).
    local missingEnvelope=Manifest.entry('T_SHADOWSTEP')
    local broken={}
    for k,v in pairs(missingEnvelope) do broken[k]=v end
    broken.movement={}
    for k,v in pairs(missingEnvelope.movement) do broken.movement[k]=v end
    broken.movement.radius='unknown'
    local unavailable=Guard.landingCandidates(nil,broken,{x=2,y=2},{x=5,y=2},{w=10,h=10})
    check(unavailable==nil,'an unreadable radius yields no candidate set (fail closed)')
    -- The same helper class: a no-plan requested-grid descriptor is
    -- movement_plan_unavailable.
    local leapEntry={movement={center='requested_grid',radius=1}}
    check(select(2,Guard.landingCandidates(nil,leapEntry,{x=2,y=2},{x=5,y=2},{w=10,h=10}))
        =='movement_plan_unavailable',
        'a no-plan requested_grid envelope is movement_plan_unavailable')
end

-- S3 G-U1..G-U6 (REAL_GIANT_LEAP_TG, uber/str.lua:38-40): the actual-centered
-- radius-1 weapon/daze leap. The completed pre-commit union is the COMPLETE
-- component x candidate expansion (D1), never the analytic circle; the raised
-- tg's selffire=false is copied into every expansion and distinguished from
-- absence/default (D3); a partial expansion is never measured.
do
    local Fixtures=assert(loadfile(root..'/tests/s3_real_specs.lua'))()
    local fixture=Fixtures.REAL_GIANT_LEAP_TG
    local copy=fixture.build()
    Fixtures.assertFields(fixture,copy,'G-series giant leap spec copy')
    Fixtures.assertRawPresence(fixture,copy,'G-series giant leap spec copy')
    check(copy.type=='ball' and copy.selffire==false and copy.radius==1 and copy.range==10,
        'the real Giant Leap raised spec is a ball with selffire=false and no FF/friendlyblock keys')
    -- G-U1 (factory): the exact descriptor/component and the real-spec radius.
    local entry=Manifest.entry('T_GIANT_LEAP')
    check(entry~=nil and Factory.validateComposition(entry)==true,
        'Giant Leap is admitted with a valid closed composition (G-U1)')
    check(entry.movement.delivery=='leap' and entry.movement.traverses==false
        and entry.movement.radius==1 and entry.movement.min_radius==0
        and entry.movement.builder_shape=='ball' and entry.movement.relocates_other==false
        and entry.movement.center=='requested_grid' and entry.movement.landing=='bounded_alternatives',
        'the movement half is the exact grid_move_bounded leap descriptor (G-U1)')
    check(#entry.components==1 and entry.components[1].id=='giant_leap_weapon_daze'
        and entry.components[1].center=='actual_landing'
        and entry.components[1].radius.from=='target'
        and entry.components[1].selffire==0 and entry.components[1].friendlyfire==100,
        'the effect half is the exact actual_landing ball component with radius {from=target} (G-U1)')
    check(entry.movement_postcondition.unchanged=='mismatch',
        'the postcondition mode is mismatch (G-U1)')
    check(Manifest.UNSUPPORTED and (function()
        for _,u in ipairs(Manifest.UNSUPPORTED) do
            if u.talent=='T_GIANT_LEAP' then return true end
        end
    end)()==nil,'the Giant Leap unsupported row is removed (G-U1)')

    local guard,leapGuard=build{defs={T_GIANT_LEAP={target=function() return copy end}},
        policy={safety={max_selffire_risk=0}}},nil
    leapGuard=build{defs={T_GIANT_LEAP={target=function() return fixture.build() end}},
        policy={safety={max_selffire_risk=0}}}
    -- G-U2: a deterministic request annotation gives ONE candidate; a bounded
    -- request enumerates the full radius-1 candidate set.
    local deterministic=Guard.landingCandidates({kind='grid',x=6,y=2,
        annotation={landing={kind='deterministic',center={x=6,y=2}}}},entry,{x=2,y=2},
        {x=5,y=2},{w=10,h=10})
    check(deterministic and deterministic.kind=='deterministic' and #deterministic.cells==1
        and deterministic.cells[1].x==6 and deterministic.cells[1].y==2,
        'a deterministic annotation yields exactly one candidate (G-U2)')
    local boundedPlan={kind='grid',x=6,y=2,annotation={landing={kind='bounded',
        center={x=6,y=2},radius=1}}}
    local bounded=Guard.landingCandidates(boundedPlan,entry,{x=2,y=2},{x=5,y=2},{w=10,h=10})
    check(bounded and #bounded.cells==9,
        'a bounded request enumerates the full radius-1 candidate set (G-U2)')
    -- G-U3: one expansion per candidate; the union is contained in radius two;
    -- self membership is true but selffire=0 removes the self risk.
    local leapAttempt={action='use_talent',talent='T_GIANT_LEAP',bound_target=2,plan=boundedPlan}
    local verdict=leapGuard(leapAttempt)
    check(verdict~=nil and verdict.action=='permit',
        'Giant Leap with selffire=0 and no allies permits (G-U3)',verdict and verdict.reason)
    local comp=verdict and verdict.detail and (function()
        for _,c in ipairs(verdict.detail.components or {}) do
            if c.id=='giant_leap_weapon_daze' then return c end
        end
    end)()
    check(comp and comp.required_expansions==9 and comp.completed_expansions==9
        and comp.candidate_count==9 and comp.footprint_count==25,
        'one expansion per candidate (9/9); the completed union is exactly the '
        ..'radius-2 square around the request (25 cells) (G-U3)',comp)
    check(comp and comp.self_excluded==true and comp.footprint_backend=='model',
        'self membership is true but selffire=0 excludes the mover from self risk '
        ..'(self_excluded evidence, G-U3/G-U5)')
    -- G-U4: an ally inside the completed union gives known FF risk; outside
    -- gives zero; an unseen union cell gives unknown (never measured partially).
    local allyAt=function(cx,cy)
        local g=build{defs={T_GIANT_LEAP={target=function() return fixture.build() end}},
            allies={{id=3,x=8,y=2}},policy={safety={max_selffire_risk=0}}}
        local ally={x=8,y=2}
        if cx then ally.x,ally.y=cx,cy end
        local guard2=build{defs={T_GIANT_LEAP={target=function() return fixture.build() end}},
            allies={ally},policy={safety={max_selffire_risk=0}}}
        return guard2(leapAttempt)
    end
    local inside=allyAt(8,2)
    check(inside and inside.action=='reject' and inside.reason=='selffire_risk'
        and inside.detail and inside.detail.measurement==100
        and inside.detail.friendlies==1 and inside.detail.risk=='friendly',
        'an ally inside the completed union gives known friendly risk 100 (G-U4)',
        inside and inside.detail and inside.detail.measurement)
    local outside=allyAt(9,2)
    check(outside and outside.action=='permit',
        'an ally outside the completed union gives zero risk (G-U4)')
    -- Unseen union cell -> unknown (fail closed).
    local unseenGuard=build{defs={T_GIANT_LEAP={target=function() return fixture.build() end}},
        allies={},known=function(x,y) if x==4 and y==1 then return false end return true end,
        policy={safety={max_selffire_risk=0}}}
    local unseen=unseenGuard(leapAttempt)
    check(unseen and unseen.action=='reject' and unseen.reason=='selffire_risk'
        and unseen.detail and unseen.detail.unknown==true,
        'an unseen grid inside the completed union fails closed (G-U4)',unseen and unseen.reason)
    -- G-U5: inject an expansion failure at the first, middle and last candidate;
    -- all three yield unknown with completed<required; a partial union is never
    -- measured.
    local function failingExpand(at)
        local calls=0
        return function(spec,opts)
            calls=calls+1
            if calls==at then return nil,'native_failed' end
            local set,add=Footprint.newSet()
            add(spec.origin.x,spec.origin.y)
            return set,'model'
        end,calls
    end
    local function expansion(at)
        local seen=0
        local set,stats=Guard.expandComplete(Manifest.entry('T_GIANT_LEAP').components[1],
            bounded,{x=5,y=2},1,{selffire=false},
            {expand=function(spec,opts)
                seen=seen+1
                if seen==at then return nil,'native_failed' end
                local s2,add=Footprint.newSet()
                add(spec.origin.x,spec.origin.y)
                return s2,'model'
            end})
        return set,stats,seen
    end
    for _,at in ipairs({1,5,9}) do
        local set,stats,seen=expansion(at)
        check(set==nil and stats.failure and stats.required>=at
            and stats.completed==math.min(at-1,stats.required),
            'an injected expansion failure at candidate '..at..' discards the partial '
            ..'union (completed<required, G-U5)',stats and stats.completed)
    end
    -- And a first-pair native failure through the production path is unknown.
    local nativeGuard=build{defs={T_GIANT_LEAP={target=function() return fixture.build() end}},
        native={game=nil},policy={safety={max_selffire_risk=0}}}
    local nativeVerdict=nativeGuard(leapAttempt)
    check(nativeVerdict and nativeVerdict.action=='reject'
        and nativeVerdict.reason=='selffire_risk' and nativeVerdict.detail
        and nativeVerdict.detail.unknown==true,
        'a native expansion failure yields unknown, never a partial union (G-U5)',
        nativeVerdict and nativeVerdict.reason)
    -- G-U6: the real raised spec's flags are copied to EACH expansion; an
    -- explicit false is distinguishable from absence/default.
    local captured={}
    Footprint.expand=
    (function(original) return original end)(Footprint.expand)
    local specCapture=function(spec,opts)
        captured[#captured+1]={type=spec.type,selffire=spec.selffire,
            friendlyfire=spec.friendlyblock~=nil and spec.friendlyblock or nil,
            radius=spec.radius,origin={x=spec.origin.x,y=spec.origin.y}}
        local set,add=Footprint.newSet()
        add(spec.origin.x,spec.origin.y)
        return set,'model'
    end
    local g6set,g6stats=Guard.expandComplete(Manifest.entry('T_GIANT_LEAP').components[1],
        bounded,{x=5,y=2},1,{selffire=false},{expand=specCapture})
    check(#captured==9,'one captured expansion per candidate (G-U6)')
    local flagsOk=true
    for _,cap in ipairs(captured) do
        if cap.selffire~=false or cap.friendlyblock~=nil then flagsOk=false end
    end
    check(flagsOk,'each expansion carries the copied selffire=false and no friendlyblock '
        ..'key (explicit false, not absence-as-false) (G-U6)')
    -- Raw vs normalized evidence: the raised_flags evidence keeps raw presence.
    local leapDetail=verdict and verdict.detail or {}
    local leapComp=leapDetail.components and leapDetail.components[1]
    check(leapComp and type(leapComp.raised_flags)=='table'
        and leapComp.raised_flags.selffire==false and leapComp.raised_flags.friendlyfire==nil,
        'the raised_flags evidence is the RAW presence map (selffire=false present, '
        ..'friendlyfire absent) (D3/G-U6)',leapComp and leapComp.raised_flags)
end

-- S3-A2-R1/R2 fix regressions (the review falsification lines, reproduced on
-- the REAL Giant Leap raised spec through the production guard).
do
    local Fixtures=assert(loadfile(root..'/tests/s3_real_specs.lua'))()
    local fixture=Fixtures.REAL_GIANT_LEAP_TG
    local caster={uid=1,x=2,y=2,canProject=function() return true end}
    local hostile={uid=2,x=5,y=2}
    local friendly={uid=3,x=4,y=2}
    local function makeGuard(spec,allies)
        return Guard.build{
            game={player=caster,level={map={w=10,h=10}}},source=caster,
            policy={safety={max_selffire_risk=0}},
            resolve=function() return hostile end,
            allies=function() return allies or {} end,
            known=function() return true end,
            getDef=function(id)
                if id=='T_GIANT_LEAP' then return {target=function() return spec end} end
            end,
            blockPath=function() return false end,details=Details}
    end
    local fullPlan={kind='grid',x=6,y=2,annotation={landing={kind='bounded',
        center={x=6,y=2},radius=1}}}
    local leapAttempt={action='use_talent',talent='T_GIANT_LEAP',bound_target=2,plan=fullPlan}
    -- Reviewer FULL_REAL_SPEC line: the complete radius-1 envelope rejects with
    -- the known friendly risk.
    local fullVerdict=makeGuard(fixture.build(),{friendly})(leapAttempt)
    check(fullVerdict and fullVerdict.action=='reject' and fullVerdict.reason=='selffire_risk'
        and fullVerdict.detail and fullVerdict.detail.candidate_count==9
        and fullVerdict.detail.measurement==100,
        'the full bounded landing envelope finds the friendly (reviewer FULL_REAL_SPEC line)',
        fullVerdict and fullVerdict.detail and fullVerdict.detail.candidate_count)
    -- Reviewer SHORT_REAL_SPEC line: the SAME plan with NO readable landing
    -- annotation is never reclassified as a deterministic one-cell measured
    -- set (it silently permitted before); it fails closed as an unknown
    -- landing envelope.
    local shortVerdict=makeGuard(fixture.build(),{friendly})({action='use_talent',
        talent='T_GIANT_LEAP',bound_target=2,plan={kind='grid',x=6,y=2}})
    check(shortVerdict and shortVerdict.action=='reject' and shortVerdict.reason=='selffire_risk'
        and shortVerdict.detail and shortVerdict.detail.unknown==true
        and shortVerdict.detail.reason=='landing_envelope_unavailable',
        'a grid plan with NO landing annotation fails closed (reviewer SHORT_REAL_SPEC '
        ..'line: never permit, never a one-cell measured set)',
        shortVerdict and shortVerdict.detail and shortVerdict.detail.reason)
    -- A present-but-malformed bounded landing (missing centre/radius) and a
    -- deterministic record that disagrees with the requested grid are unknown
    -- too, never silently re-anchored.
    local malformed=makeGuard(fixture.build(),{})({action='use_talent',talent='T_GIANT_LEAP',
        bound_target=2,plan={kind='grid',x=6,y=2,annotation={landing={kind='bounded'}}}})
    check(malformed and malformed.action=='reject' and malformed.detail
        and malformed.detail.unknown==true,
        'a present-but-malformed bounded landing fails closed (R1)',
        malformed and malformed.detail and malformed.detail.reason)
    local disagreed=makeGuard(fixture.build(),{})({action='use_talent',talent='T_GIANT_LEAP',
        bound_target=2,plan={kind='grid',x=6,y=2,annotation={landing={kind='deterministic',
            center={x=7,y=2}}}}})
    check(disagreed and disagreed.action=='reject' and disagreed.detail
        and disagreed.detail.unknown==true,
        'a deterministic landing that disagrees with the requested grid fails closed (R1)',
        disagreed and disagreed.detail and disagreed.detail.reason)
    -- Reviewer SPARSE_CANDIDATES line: a sparse candidate list is never
    -- truncated by ipairs into a 1/1 complete measured set; the
    -- complete-expansion boundary rejects it before any expansion call.
    local sparseCandidates={kind='bounded',cells={[1]={x=6,y=2},[3]={x=4,y=2}},
        center={x=6,y=2},radius=2}
    local calls=0
    local sparseSet,sparseStats=Guard.expandComplete(
        Manifest.entry('T_GIANT_LEAP').components[1],sparseCandidates,hostile,1,
        {selffire=false},
        {expand=function(spec)
            calls=calls+1
            local s,add=Footprint.newSet(); add(spec.origin.x,spec.origin.y)
            return s,'model'
        end})
    check(sparseSet==nil and sparseStats and sparseStats.failure=='candidates_not_dense'
        and calls==0,
        'a sparse candidate list is rejected at the expansion boundary (reviewer '
        ..'SPARSE_CANDIDATES line: never 1/1 complete, never a hidden member)',
        sparseStats and sparseStats.failure)
    -- The total required pair count is independent of an early expansion
    -- failure: a first-pair failure still reports the full applicable count.
    local earlyCandidates=Guard.landingCandidates(fullPlan,
        Manifest.entry('T_GIANT_LEAP'),caster,hostile,{w=10,h=10})
    check(earlyCandidates and #earlyCandidates.cells==9,
        'the bounded plan enumerates the nine radius-1 candidates (R1)',
        earlyCandidates and #earlyCandidates.cells)
    local seen=0
    local earlySet,earlyStats=Guard.expandComplete(
        Manifest.entry('T_GIANT_LEAP').components[1],earlyCandidates,hostile,1,{selffire=false},
        {expand=function()
            seen=seen+1
            if seen==1 then return nil,'native_failed' end
            local s,add=Footprint.newSet(); add(99,99)
            return s,'model'
        end})
    check(earlySet==nil and earlyStats and earlyStats.required==9
        and earlyStats.completed==0 and earlyStats.failure=='native_failed',
        'the required pair count is independent of an early expansion failure (R1)',
        earlyStats and ('required='..tostring(earlyStats.required)..' completed='
            ..tostring(earlyStats.completed)))

    -- R2 regressions: the FULL engine-consulted raised field set (real raised
    -- force_max_range from spells/golem.lua:271-272 / thaumaturgy.lua:234 and
    -- real block_path=false/block_radius=false from
    -- corruptions/shadowflame.lua:157) is forwarded from the live raised spec
    -- THROUGH THE PRODUCTION GUARD into every expansion spec (never dropped,
    -- explicit false preserved).
    local live={type='ball',range=10,radius=1,selffire=false,
        -- golem.lua:272 / thaumaturgy.lua:234 raise force_max_range=true.
        force_max_range=true,
        -- shadowflame.lua:157 raises block_path=false, block_radius=false,
        -- requires_knowledge=false, pass_terrain=true.
        block_path=false,block_radius=false,requires_knowledge=false,
        pass_terrain=true,
        min_range=1,
        grid_exclude={[6]={[2]=true}},
        filter=function() return true end}
    local captured={}
    local originalExpand=Footprint.expand
    local okCapture,allowErr
    okCapture=pcall(function()
        Footprint.expand=function(spec,opts)
            local copy={}
            for k,v in pairs(spec) do copy[k]=v end
            captured[#captured+1]=copy
            local s,add=Footprint.newSet()
            add(spec.origin.x,spec.origin.y)
            return s,'model'
        end
        local verdict=makeGuard(live,{})({action='use_talent',talent='T_GIANT_LEAP',
            bound_target=2,plan=fullPlan})
        allowErr=verdict and verdict.action or tostring(verdict)
    end)
    Footprint.expand=originalExpand
    check(okCapture and #captured==9 and allowErr=='permit',
        'the live raised spec reaches every expansion through the production guard (R2)',
        tostring(allowErr)..' captured='..#captured)
    local flagsOk=true
    for _,spec in ipairs(captured) do
        if spec.force_max_range~=true or spec.min_range~=1 or spec.block_path~=false
            or spec.block_radius~=false or spec.requires_knowledge~=false
            or spec.pass_terrain~=true or type(spec.grid_exclude)~='table'
            or type(spec.filter)~='function' or spec.selffire~=false then
            flagsOk=false
        end
    end
    check(flagsOk and #captured>0,
        'every engine-consulted raised field (force_max_range/min_range/grid_exclude/'
        ..'filter/block_path/block_radius/requires_knowledge/pass_terrain) is forwarded '
        ..'into each expansion with explicit false preserved (R2)',
        captured[1] and {fp=captured[1].force_max_range,bp=captured[1].block_path,
            br=captured[1].block_radius})
end

-- S3 V-U3 + X-U2 (REAL_VAULT_ACTOR_TG, techniques/agility.lua:92-93): both
-- direct Vault components are evidenced, risk-exempt, and resolved against the
-- bound hostile; a missing or self-bound actor fails; the strict vs tolerant
-- threshold changes only the policy verdict, never the evaluation.
do
    local Fixtures=assert(loadfile(root..'/tests/s3_real_specs.lua'))()
    local actorFixture=Fixtures.REAL_VAULT_ACTOR_TG
    local actorCopy=actorFixture.build()
    Fixtures.assertFields(actorFixture,actorCopy,'V-U3 vault actor spec copy')
    Fixtures.assertRawPresence(actorFixture,actorCopy,'V-U3 vault actor spec copy')
    local plan={kind='grid',x=4,y=2,annotation={landing={kind='bounded',
        center={x=4,y=2},radius=1}}}
    -- The real prompt-one range is 1, so the bound hostile sits at melee range.
    local function vaultGuard(policyOverrides)
        local caster={uid=1,x=2,y=2,canProject=function() return true end}
        local hostile={uid=2,x=3,y=2}
        local g=Guard.build({game={player=caster,level={map={w=10,h=10}}},
            policy=policyOverrides or {safety={max_selffire_risk=0}},source=caster,
            resolve=function(id) return id==2 and hostile or nil end,
            allies=function() return {} end,known=function() return true end,
            getDef=function(id) return id=='T_VAULT'
                and {target=function() return actorFixture.build() end} or nil end,
            blockPath=function() return false end,details=Details})
        return g,caster,hostile
    end
    local guard=vaultGuard()
    local verdict=guard({action='use_talent',talent='T_VAULT',bound_target=2,plan=plan})
    check(verdict~=nil and verdict.action=='permit',
        'the two direct Vault components are risk-exempt (permit at threshold 0) (V-U3)',
        verdict and verdict.reason)
    local detail=verdict and verdict.detail or {}
    check(detail.components_evaluated==2,
        'both direct components are evaluated and evidenced (V-U3)')
    local comps=detail.components or {}
    check(comps[1] and comps[1].id=='vault_strike' and comps[1].phase=='melee'
        and comps[1].delivery=='attackTarget' and comps[1].center=='target'
        and comps[2].id=='vault_daze' and comps[2].delivery=='attackTarget'
        and comps[2].center=='target',
        'the components are the exact direct records (strike then daze) (V-U3)')
    check(detail.measurement==0,
        'direct bound-hostile components contribute zero self/friendly risk (V-U3)')
    -- Missing bound actor fails before footprint work.
    local g=vaultGuard()
    check(g({action='use_talent',talent='T_VAULT',bound_target=404,plan=plan})~=nil
        and g({action='use_talent',talent='T_VAULT',bound_target=404,plan=plan}).reason=='target_lost',
        'a missing bound hostile is target_lost before any footprint work (V-U3)')
    -- A self-bound actor is not executable.
    local selfGuard=build{defs={T_VAULT={target=function() return actorFixture.build() end}},
        resolveSelf=true,policy={safety={max_selffire_risk=0}}}
    -- (the test's build resolves the shared dummy; simulate a self binding by
    -- binding to the player uid and pointing resolve at the player.)
    local selfCtxGuard=Guard.build({game={player={uid=1,x=2,y=2,canProject=function() return true end},
        level={map={w=10,h=10}}},policy={safety={max_selffire_risk=0}},
        source={uid=1,x=2,y=2,canProject=function() return true end},
        resolve=function() return {uid=1,x=2,y=2} end,allies=function() return {} end,
        known=function() return true end,getDef=function() return nil end,
        blockPath=function() return false end,details=Details})
    -- Use a distinct source/target pair where the bound actor IS the caster.
    local caster={uid=7,x=2,y=2,canProject=function() return true end}
    local selfResolveGuard=Guard.build({game={player=caster,level={map={w=10,h=10}}},
        policy={safety={max_selffire_risk=0}},source=caster,
        resolve=function(id) return id==7 and caster or nil end,
        allies=function() return {} end,known=function() return true end,
        getDef=function(id) return id=='T_VAULT' and {target=function() return actorFixture.build() end} or nil end,
        blockPath=function() return false end,details=Details})
    local selfVerdict=selfResolveGuard({action='use_talent',talent='T_VAULT',bound_target=7,plan=plan})
    check(selfVerdict~=nil and selfVerdict.action=='reject' and selfVerdict.reason=='target_lost',
        'a self-bound Vault actor fails closed (V-U3)',selfVerdict and selfVerdict.reason)
    -- X-U2: a tolerant threshold permits the same mixed evaluation with identical
    -- footprint/composition evidence.
    local tolerant=vaultGuard({safety={max_selffire_risk=100}})
    local tolerantVerdict=tolerant({action='use_talent',talent='T_VAULT',bound_target=2,plan=plan})
    check(tolerantVerdict~=nil and tolerantVerdict.action=='permit',
        'a tolerant threshold permits the same mixed entry (X-U2)')
    local tolerantDetail=tolerantVerdict and tolerantVerdict.detail or {}
    check(tolerantDetail.candidate_count==(detail.candidate_count)
        and tolerantDetail.components_evaluated==(detail.components_evaluated)
        and #(tolerantDetail.components or {})==#comps,
        'the composition evidence is unchanged by the threshold (X-U2)')
end

-- S3-A2-FIX1-01/FIX1-02 regressions: the plan/annotation/landing discriminated
-- union is validated BEFORE any member read (a scalar annotation must not throw;
-- a cross-kind malformed landing must be unknown, never a measured one-cell
-- set), and the risk model honours the raised `act_exclude` BY UID plus the
-- effective live `friendlyfire` VALUE (not only its transport).
-- The reviewer's exact falsification lines are reproduced here through the
-- production guard.
do
    local Fixtures=assert(loadfile(root..'/tests/s3_real_specs.lua'))()
    local fixture=Fixtures.REAL_GIANT_LEAP_TG
    local caster={uid=1,x=2,y=2,canProject=function() return true end}
    local hostile={uid=2,x=5,y=2}
    local friendly={uid=3,x=4,y=2}
    local function makeGuard(spec,allies)
        return Guard.build{
            game={player=caster,level={map={w=10,h=10}}},source=caster,
            policy={safety={max_selffire_risk=0}},
            resolve=function() return hostile end,
            allies=function() return allies or {} end,
            known=function() return true end,
            getDef=function(id)
                if id=='T_GIANT_LEAP' then return {target=function() return spec end} end
            end,
            blockPath=function() return false end,details=Details}
    end
    local fullPlan={kind='grid',x=6,y=2,annotation={landing={kind='bounded',
        center={x=6,y=2},radius=1}}}
    -- FIX1-01(a): a SCALAR annotation must not throw; it is a typed unknown.
    local okScalar,scalarVerdict=pcall(function()
        return makeGuard(fixture.build(),{})({action='use_talent',talent='T_GIANT_LEAP',
            bound_target=2,plan={kind='grid',x=6,y=2,annotation=true}})
    end)
    check(okScalar and scalarVerdict and scalarVerdict.action=='reject'
        and scalarVerdict.reason=='selffire_risk' and scalarVerdict.detail
        and scalarVerdict.detail.unknown==true
        and scalarVerdict.detail.reason=='landing_envelope_unavailable',
        'a scalar annotation is a typed unknown, never a throw (FIX1-01)',
        tostring(okScalar)..' '..tostring(scalarVerdict and scalarVerdict.detail and scalarVerdict.detail.reason))
    -- FIX1-01(b): a cross-kind malformed landing (a `sequence` plan carrying an
    -- unknown-key landing) is unknown, never a measured one-cell set.
    local crossKind=makeGuard(fixture.build(),{friendly})({action='use_talent',
        talent='T_GIANT_LEAP',bound_target=2,
        plan={kind='sequence',annotation={landing={kind='bounded',center={x=6,y=2},radius=0,garbage=true}}}})
    check(crossKind and crossKind.action=='reject' and crossKind.reason=='selffire_risk'
        and crossKind.detail and crossKind.detail.unknown==true
        and crossKind.detail.reason=='landing_envelope_unavailable'
        and crossKind.detail.candidate_count==nil,
        'a cross-kind malformed landing is unknown, never a measured one-cell set (FIX1-01)',
        crossKind and crossKind.detail and crossKind.detail.reason)
    -- A landing admitted by the vocabulary but not for the plan kind is
    -- likewise unknown (a `step` plan defines only a deterministic landing).
    local wrongKindPlan={kind='step',direction=6,annotation={landing={kind='random',
        center={x=6,y=2},radius=1}}}
    local wrongKind=makeGuard(fixture.build(),{})({action='use_talent',talent='T_GIANT_LEAP',
        bound_target=2,plan=wrongKindPlan})
    check(wrongKind and wrongKind.action=='reject' and wrongKind.detail
        and wrongKind.detail.reason=='landing_envelope_unavailable',
        'a landing kind not admitted for the plan kind fails closed (FIX1-01)',
        wrongKind and wrongKind.detail and wrongKind.detail.reason)
    -- FIX1-02(a): the raised act_exclude is honoured BY UID; an excluded ally is
    -- not counted, exactly as the engine skips `type.act_exclude[a.uid]`.
    local excluded=makeGuard({type='ball',range=10,radius=1,selffire=false,
        act_exclude={[friendly.uid]=true}},{friendly})({action='use_talent',
        talent='T_GIANT_LEAP',bound_target=2,plan=fullPlan})
    check(excluded and excluded.action=='permit' and excluded.detail
        and excluded.detail.measurement==0,
        'act_exclude by uid removes the excluded ally from the risk model (FIX1-02)',
        excluded and tostring(excluded.detail and excluded.detail.measurement))
    -- The same ally NOT excluded still measures the friendly risk.
    local notExcluded=makeGuard({type='ball',range=10,radius=1,selffire=false,
        act_exclude={[999]=true}},{friendly})({action='use_talent',
        talent='T_GIANT_LEAP',bound_target=2,plan=fullPlan})
    check(notExcluded and notExcluded.action=='reject'
        and notExcluded.detail and notExcluded.detail.measurement==100,
        'an ally not listed in act_exclude is still measured (FIX1-02)',
        notExcluded and tostring(notExcluded.detail and notExcluded.detail.measurement))
    -- FIX1-02(b): a malformed (non-table) act_exclude cannot reproduce the
    -- engine's indexing; it is a typed unknown and fails closed (never permit).
    local malformed=makeGuard({type='ball',range=10,radius=1,selffire=false,
        act_exclude=true},{})({action='use_talent',talent='T_GIANT_LEAP',bound_target=2,
        plan=fullPlan})
    check(malformed and malformed.action=='reject' and malformed.reason=='selffire_risk'
        and malformed.detail and malformed.detail.unknown==true
        and malformed.detail.reason=='act_exclude_not_a_table',
        'a non-table act_exclude is a typed unknown and fails closed (FIX1-02)',
        malformed and malformed.detail and malformed.detail.reason)
    -- FIX1-02(c): a LIVE friendlyfire=false overrides the manifest's static
    -- harmful default; membership/risk is derived from the effective raised
    -- value, so the same action permits (not 100).
    local liveFF=makeGuard({type='ball',range=10,radius=1,selffire=false,friendlyfire=false},
        {friendly})({action='use_talent',talent='T_GIANT_LEAP',bound_target=2,plan=fullPlan})
    check(liveFF and liveFF.action=='permit' and liveFF.detail
        and liveFF.detail.measurement==0,
        'a live friendlyfire=false overrides the static manifest default (FIX1-02)',
        liveFF and tostring(liveFF.detail and liveFF.detail.measurement))
end

print('Auto-combat guard: '..checks..' checks passed')
