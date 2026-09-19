-- GPL-3.0-or-later. Manifest-driven pre-execution safety guard (v2).
--
-- For a selected hostile action this module:
--   1. requires the version-pinned manifest entry;
--   2. resolves each canonical component's declarative condition from audited
--      scalar reads (a branch that cannot be resolved is kept, producing the
--      conservative union);
--   3. expands the exact footprint of every active component (native backend
--      when the engine geometry is present, pure model otherwise);
--   4. composes self/friendly risk per delivery path, measures the aggregate
--      and compares it with the policy's `max_selffire_risk`: a known value at
--      or below tolerance is permitted, above it is rejected, and only an
--      incalculable footprint fails closed.
--
-- It returns nil (no measurable risk) or `{action='permit',detail=...}` to
-- permit the native executor, or a verdict table
-- `{action='reject'|'pause',reason=...,detail=...}`. It never commits an action
-- and never calls a talent action entrypoint.
local Manifest=require 'mod.auto_combat.EffectManifest'
local Footprint=require 'mod.auto_combat.EffectFootprint'
local Risk=require 'mod.auto_combat.EffectRisk'
local Factory=require 'mod.auto_combat.MovementAdapterFactory'
local Distance=require 'mod.mcp_bridge.Distance'
local M={}

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end

-- Resolve a declarative condition. `readAttr(id)` and `talentLevel(id)` are the
-- audited scalar providers; an unavailable read returns 'unknown' so the branch
-- stays in the conservative union.
local function resolveWhen(when,providers)
    if when==nil or when.kind==nil or when.kind=='always' then return true end
    if when.kind=='talent_level' then
        local level=providers.talentLevel()
        if not finite(level) then return 'unknown' end
        if when.at_least~=nil then return level>=when.at_least end
        if when.below~=nil then return level<when.below end
        return 'unknown'
    end
    if when.kind=='attr' then
        local value=providers.readAttr(when.id)
        -- A successful read of an absent attribute is a false branch; only a
        -- failed/unavailable read is unknown (kept in the conservative union).
        if value=='unknown' then return 'unknown' end
        return value~=nil and value~=false and value~=0
    end
    return 'unknown'
end

-- Resolve a component filter value: an audited dynamic input (for example
-- `spellFriendlyFire`) becomes its live scalar, or `unknown` when the provider
-- is unavailable/erroring (the guard then fails closed).
local function resolveDynamic(value,ctx,talent,def)
    if type(value)=='table' and value.dynamic then
        if type(ctx.dynamicScalar)~='function' then return 'unknown' end
        local ok,result=pcall(ctx.dynamicScalar,value.dynamic,talent,def)
        if not ok then return 'unknown' end
        return result
    end
    return value
end

local function isDynamicInput(value)
    return type(value)=='table' and value.dynamic~=nil
end

-- Resolve a component radius declared as `{from='target'}` from the live
-- builder spec; an unavailable radius is unknown and fails closed.
local function resolveRadius(value,typ)
    if type(value)=='table' and value.from=='target' then
        if typ and finite(typ.radius) then return typ.radius end
        return 'unknown'
    end
    return value
end

-- Map a component's AoE centre and aim direction to a pure footprint spec.
-- `center='self'` centres the effect on the caster; `direction='target'` keeps
-- the bound target as the aim vector. The source-centred Burning Wake cone is
-- `center='self', direction='target'`: the native `Map:addEffect` places the
-- effect at the caster but passes the target delta as its direction, so the
-- footprint must not collapse the direction to zero.
function M.footprintSpec(component,origin,bound,flags)
    local tx,ty=bound.x,bound.y
    if component.direction~='target' and (component.center or 'target')=='self' then
        tx,ty=origin.x,origin.y
    end
    local spec={shape=component.shape,range=component.range,radius=component.radius,angle=component.angle,
        map_effect=component.delivery=='map_effect',
        origin={x=origin.x,y=origin.y},target={x=tx,y=ty}}
    -- A′ §6.4: the raised spec's ACTUAL static flags must reach the native
    -- footprint input. The engine uses `friendlyblock` to let a friendly actor
    -- NOT block the projection (Target.lua:527-535,588-607,657-664), so a probe
    -- rebuilt from geometry alone can manufacture a false blocked line.
    if type(flags)=='table' then
        for _,key in ipairs({'friendlyblock','friendlyfire','nolock',
                'pass_terrain','nowarning','no_restrict','requires_knowledge'}) do
            if flags[key]~=nil then spec[key]=flags[key] end
        end
    end
    return spec
end

-- Union of footprints for the component list; a component whose condition is
-- unknown is included conservatively.
local function footprintFor(component,ctx,target,flags)
    local p=ctx.source
    local spec=M.footprintSpec(component,p,target,flags)
    local tx,ty=spec.target.x,spec.target.y
    local set,backend=Footprint.expand(spec,{native=ctx.native,blockPath=ctx.blockPath,
        blockRadius=ctx.blockRadius})
    return set,backend,tx,ty
end

local function playerOverride(component,typ,ctx)
    if component.delivery~='projectile' then return true end
    -- Native evaluates `typ.player_selffire or act.allow_player_selffire`: a
    -- component/spec opt-in short-circuits, and `false` in one source never
    -- vetoes `true` in the other.
    if component.player_selffire then return true end
    return ctx.details.playerSelfOverride(ctx.source,typ or {})
end

local function memberships(component,set,ctx,typ)
    local p=ctx.source
    local m={}
    m.player_override=playerOverride(component,typ,ctx)
    if set==nil then return {self='unknown',friendlies='unknown',player_override=m.player_override} end
    m.self=Footprint.at(set,p.x,p.y) and true or false
    local ff=Risk.flag(component.friendlyfire)
    if ff==0 then
        m.friendlies=0
        return m
    end
    local count=0
    local unknown=false
    for _,ally in ipairs(ctx.allies() or {}) do
        if finite(ally.x) and finite(ally.y) then
            if Footprint.at(set,ally.x,ally.y) then count=count+1 end
        end
    end
    -- A harmful footprint that reaches grids the player has not seen has
    -- unknown occupancy; fail closed rather than assume it is empty.
    if ctx.known then
        for x,column in pairs(set) do
            for y in pairs(column) do
                local known=ctx.known(x,y)
                if known==false then unknown=true end
            end
        end
    end
    m.friendlies=unknown and 'unknown' or count
    return m
end

-- Public pure conformance helper: the observed native cursor must belong to the
-- entry's declared union (or match `conformance` when no union is declared).
-- This is a compatibility diagnostic, not the pre-commit proof.
function M.conformance(entry,typ)
    if type(typ)~='table' then return nil,'builder_missing' end
    local shape=typ.type
    if entry.union then
        for _,candidate in ipairs(entry.union) do
            if candidate==shape then return true end
        end
        return nil,'shape_not_in_union'
    end
    if entry.conformance and entry.conformance.shape and entry.conformance.shape~=shape then
        return nil,'shape_mismatch'
    end
    return true
end

function M.build(ctx)
    local p=ctx.source

    -- A′ §6.4 (Dwarven projection fidelity): these stationary programs build
    -- their cursor spec as a LOCAL table inside `action` — there is no callable
    -- `t.target` builder — so "the real shape" is this curated copy of the
    -- flags those local tables actually carry. The static flags MUST reach both
    -- the `canProject` precheck and the native footprint input: the engine uses
    -- `friendlyblock` to let a friendly actor NOT block the projection
    -- (`engines/default/engine/Target.lua:527-535,588-607,657-664`) and
    -- `friendlyfire` to decide the friendly filter, so a probe rebuilt from
    -- `{type,range,talent}` alone can manufacture a false `no_line_of_sight`.
    -- Sources: `spells/stone.lua:38,45,53` (no filter fields -> engine defaults
    -- friendlyfire=true/actorblock=true) and `gifts/dwarven-nature.lua:34,41,49`
    -- (`friendlyfire=false, friendlyblock=false` at EVERY position).
    local STATIONARY_SPECS={
        T_EARTHEN_MISSILES={type='bolt'},
        T_DWARVEN_HALF_EARTHEN_MISSILES={type='bolt',friendlyfire=false,
            friendlyblock=false},
    }
    -- Build the probe spec for one chosen grid from the curated static flags.
    local function stationaryProbeSpec(entry,talent,range)
        local curated=STATIONARY_SPECS[talent]
        local shape=curated and curated.type
            or (entry.cursor and entry.cursor.shape) or 'bolt'
        local spec={type=shape,range=range,talent=talent}
        if curated then
            for _,key in ipairs({'friendlyfire','friendlyblock','nolock',
                    'pass_terrain','nowarning'}) do
                if curated[key]~=nil then spec[key]=curated[key] end
            end
        end
        return spec
    end

    -- A′ §6.5: stationary guard routing is a VALIDATED CONSEQUENCE of the
    -- resolved movement template, never an independent manifest boolean. A
    -- factory leaf can only carry `delivery='stationary'` when it came from the
    -- closed `stationary_sequence` template (its `delivery`/`landing`/`center`
    -- are fixed invariants a caller cannot supply), so the declared leaves are
    -- mechanical data. The resolved leaf then decides the route: a stationary
    -- leaf runs the stationary measurement; a mover leaf keeps the ordinary
    -- movement skip; an unresolvable variant fails closed.
    local function declaresStationary(entry)
        local movement=entry and entry.movement
        if type(movement)~='table' then return false end
        if movement.variants then
            for _,variant in ipairs(movement.variants) do
                if type(variant.movement)=='table'
                    and variant.movement.delivery=='stationary' then return true end
            end
            return false
        end
        return movement.delivery=='stationary'
    end
    -- `'stationary' | 'mover' | 'mixed'`: the declaration-level classification of
    -- every executable leaf. A uniform declaration routes without any runtime
    -- read (the factory proved the leaf mechanically); only a MIXED declaration
    -- needs the variant resolved, and an unresolvable one fails closed.
    local function stationaryKind(entry)
        local movement=entry and entry.movement
        if type(movement)~='table' then return 'mover' end
        local leaves={}
        if movement.variants then
            for _,variant in ipairs(movement.variants) do
                if type(variant.movement)=='table' then
                    leaves[#leaves+1]=variant.movement.delivery=='stationary'
                end
            end
        else
            leaves[1]=movement.delivery=='stationary'
        end
        if #leaves==0 then return 'mover' end
        local any,all=false,true
        for _,isStationary in ipairs(leaves) do
            if isStationary then any=true else all=false end
        end
        if all then return 'stationary' end
        if not any then return 'mover' end
        return 'mixed'
    end
    local function stationaryRoute(entry,talent,reads)
        local movement=entry.movement
        local resolved=movement
        if type(movement)=='table' and movement.variants then
            local ok,value=pcall(Factory.resolveVariant,movement,talent,reads)
            if not ok or type(value)~='table' then
                return nil,(not ok and tostring(value))
                    or 'movement_variant_unknown'
            end
            resolved=value
        end
        if type(resolved)~='table' then return false end
        return resolved.delivery=='stationary' end

    -- A′ §6.5: measure one stationary multi-prompt effect program at EVERY
    -- policy-chosen grid. The caster never moves, so the declared components are
    -- fired at each planned coordinate instead of being skipped as movement:
    --   * the precheck (`range` + `canProject`) and the native footprint input
    --     carry the REAL static flags of the raised spec (§6.4);
    --   * EVERY applicable component x planned-grid footprint must expand
    --     successfully - an unreadable one propagates `unknown` and fails
    --     closed, and a partially-readable union is never measured as complete;
    --   * every plan value must be a VALID grid (malformed values are rejected,
    --     never silently filtered);
    --   * the one measure is compared with the policy's `max_selffire_risk`.
    local function guardStationary(entry,talent,threshold,disable,attempt,providers)
        local origin={x=p.x,y=p.y}
        if not (finite(origin.x) and finite(origin.y)) then
            return disable('target_geometry_unknown',{talent=talent})
        end
        local plan=attempt.plan
        if type(plan)~='table' or plan.kind~='sequence' or type(plan.values)~='table' then
            return disable('movement_plan_unavailable',{talent=talent,
                reason='a stationary program needs its planned grids'})
        end
        local grids={}
        for index,value in ipairs(plan.values) do
            if type(value)~='table' or value.kind~='grid'
                or not finite(value.x) or not finite(value.y)
                or value.x%1~=0 or value.y%1~=0 then
                return disable('movement_plan_unavailable',{talent=talent,
                    detail='bad_plan_value',index=index})
            end
            grids[#grids+1]={x=value.x,y=value.y}
        end
        if #grids==0 then
            return disable('target_geometry_unknown',{talent=talent,
                reason='no planned grid for a stationary program'})
        end
        local range=entry.range
        for _,grid in ipairs(grids) do
            if finite(range) and Distance.grid(p.x,p.y,grid.x,grid.y)>range then
                return disable('target_out_of_range',{range=range,stationary=true,
                    x=grid.x,y=grid.y})
            end
            if type(p.canProject)~='function' then
                return disable('canproject_unavailable',{stationary=true,
                    x=grid.x,y=grid.y})
            end
            local probe=stationaryProbeSpec(entry,talent,range)
            local ok,can=pcall(p.canProject,p,probe,grid.x,grid.y)
            if not ok or can==nil then
                return disable('canproject_unknown',{stationary=true,
                    x=grid.x,y=grid.y})
            end
            if can==false then
                return disable('no_line_of_sight',{stationary=true,
                    x=grid.x,y=grid.y,friendlyblock=probe.friendlyblock,
                    friendlyfire=probe.friendlyfire})
            end
        end
        local components={}
        local membershipsBy={}
        for _,component in ipairs(entry.components or {}) do
            if component.phase~='cursor' then
                local active=resolveWhen(component.when,providers)
                if active~=false then
                    local resolved={id=component.id,phase=component.phase,
                        delivery=component.delivery,shape=component.shape,
                        range=component.range,radius=component.radius,
                        center=component.center,direction=component.direction,
                        selffire=component.selffire,friendlyfire=component.friendlyfire,
                        player_selffire=component.player_selffire,
                        provenance=component.provenance,when=component.when,
                        resolved_when=active}
                    local def=ctx.getDef(talent)
                    resolved.selffire=resolveDynamic(resolved.selffire,ctx,talent,def)
                    resolved.friendlyfire=resolveDynamic(resolved.friendlyfire,ctx,talent,def)
                    -- A′ §6.4: the raised spec's ACTUAL static flags are
                    -- authoritative over the manifest's curated default, so
                    -- `friendlyfire=false` reaches risk/effect modelling.
                    local flags=stationaryProbeSpec(entry,talent,range)
                    if flags.friendlyfire~=nil and not isDynamicInput(component.friendlyfire) then
                        resolved.friendlyfire=flags.friendlyfire
                    end
                    if flags.selffire~=nil and not isDynamicInput(component.selffire) then
                        resolved.selffire=flags.selffire
                    end
                    if finite(flags.range) then resolved.range=flags.range end
                    local needsRadius=resolved.shape=='ball' or resolved.shape=='cone'
                        or resolved.shape=='widebeam'
                    if needsRadius and not finite(resolved.radius) then
                        return disable('selffire_risk',{talent=talent,stationary=true,
                            component=resolved.id,phase=resolved.phase,unknown=true,
                            reason='radius_unknown'})
                    end
                    local union,add=Footprint.newSet()
                    local backend=nil
                    for _,grid in ipairs(grids) do
                        local spec={shape=resolved.shape,range=resolved.range,
                            radius=resolved.radius,angle=resolved.angle,
                            map_effect=resolved.delivery=='map_effect',
                            friendlyfire=flags.friendlyfire,
                            friendlyblock=flags.friendlyblock,nolock=flags.nolock,
                            pass_terrain=flags.pass_terrain,nowarning=flags.nowarning,
                            talent=talent,
                            origin={x=origin.x,y=origin.y},target={x=grid.x,y=grid.y}}
                        if resolved.center=='self' then
                            spec.target={x=origin.x,y=origin.y}
                        end
                        local set,thisBackend=Footprint.expand(spec,{native=ctx.native,
                            blockPath=ctx.blockPath,blockRadius=ctx.blockRadius})
                        -- A′ §6.5: EVERY component x grid must expand. A partial
                        -- union is never measured as complete.
                        if set==nil then
                            return disable('selffire_risk',{talent=talent,
                                stationary=true,unknown=true,component=resolved.id,
                                phase=resolved.phase,reason='footprint_unavailable',
                                backend=thisBackend,x=grid.x,y=grid.y,
                                footprint_backend=thisBackend})
                        end
                        backend=thisBackend
                        for x,column in pairs(set) do
                            for y in pairs(column) do add(x,y) end
                        end
                    end
                    resolved.footprint_backend=backend
                    components[#components+1]=resolved
                    membershipsBy[resolved.id or resolved.phase]=
                        memberships(resolved,union,ctx,flags)
                end
            end
        end
        if #components==0 then
            return disable('adapter_no_components',{talent=talent,stationary=true})
        end
        local measure=Risk.measure(components,membershipsBy)
        if measure.risk==0 then
            return {action='permit',detail={measurement=0,threshold=threshold,
                talent=talent,stationary=true,grids=#grids}}
        end
        local worst=measure.detail
        local detail={risk=worst and worst.risk or nil,measurement=measure.risk,
            threshold=threshold,unknown=measure.risk=='unknown',talent=talent,
            stationary=true,grids=#grids}
        if worst then
            detail.phase=worst.phase
            detail.component=worst.component
            detail.selffire=worst.selffire
            detail.friendlyfire=worst.friendlyfire
            detail.friendlies=worst.friendlies
            detail.provenance=worst.provenance
        end
        if measure.risk~='unknown' and type(measure.risk)=='number' and measure.risk<=threshold then
            return {action='permit',detail=detail}
        end
        return disable('selffire_risk',detail)
    end

    -- Any integrity/uncertainty fault disables this action (the design's §8.1
    -- "disable that action" rule), leaving other complete actions eligible.
    local function disable(reason,detail)
        return {action='reject',reason=reason,detail=detail}
    end

    local function guard(attempt)
        local action=attempt.action
        if action~='attack' and action~='use_talent' then return nil end
        if not p then return {action='reject',reason='actor_unavailable'} end
        local talent=action=='attack' and 'T_ATTACK' or attempt.talent
        local entry=Manifest.entry(talent)
        if not entry then return {action='reject',reason='unsupported_adapter'} end
        local policy=ctx.policy
        local threshold=policy and policy.safety and policy.safety.max_selffire_risk
        if type(threshold)~='number' then threshold=0 end
        -- NO-AUDIT (v1.6): there is no source-identity/digest gate. Lua is dynamic
        -- and any addon may replace a getter/builder; the guard uses the game's
        -- actual live functions as normal entrypoints. A missing/erroring/non-table
        -- builder below is a derivation unknown, not an identity rejection.
        -- Movement adapters: a pure movement entry carries no damage footprint
        -- (its landing/uncertainty safety is the MovementPlanner's explicit
        -- policy acceptance). A′ §6.5: a stationary multi-prompt effect program
        -- is NOT movement — the caster never moves — so it must NOT be skipped:
        -- the resolved factory leaf routes it to the stationary measurement
        -- below. Routing is a validated consequence of the resolved template,
        -- never an independent manifest boolean.
        local providers={
            talentLevel=function()
                -- Effective level (`self:getTalentLevel(t)`), never raw points:
                -- a raw investment can be lower than the effective level through
                -- mastery/alterations. Unavailable -> unknown -> conservative.
                if type(ctx.talentLevel)~='function' then return 'unknown' end
                local ok,value=pcall(ctx.talentLevel,talent,ctx.getDef(talent))
                if not ok then return 'unknown' end
                return value
            end,
            readAttr=function(id)
                if type(p.attr)~='function' then return 'unknown' end
                local ok,value=pcall(p.attr,p,id)
                if not ok then return 'unknown' end
                return value
            end,
        }
        if entry.kind=='movement' then
            local routing=stationaryKind(entry)
            if routing=='mover' then return nil end
            if routing=='mixed' then
                -- Only a mixed declaration needs the variant resolved; an
                -- indeterminate read fails closed (plugin undecidability).
                local reads={talentLevel=providers.talentLevel,attr=providers.readAttr}
                local isStationary,routeErr=stationaryRoute(entry,talent,reads)
                if isStationary==nil then
                    return disable('movement_variant_unknown',{talent=talent,
                        dependency='movement.delivery',detail=routeErr})
                end
                if not isStationary then return nil end
            end
            return guardStationary(entry,talent,threshold,disable,attempt,providers)
        end
        if entry.target~='hostile' then return nil end
        local target
        if attempt.bound_target then target=ctx.resolve(attempt.bound_target) end
        if not target then return disable('target_lost') end
        if not (finite(target.x) and finite(target.y) and finite(p.x) and finite(p.y)) then
            return disable('target_geometry_unknown')
        end
        -- Melee delivery never consults ActorProject filters.
        if entry.melee then return nil end
        -- Real target spec from the audited native builder when available; the
        -- manifest remains the canonical source for secondary/ground/variants.
        local typ,builderSource=nil,'manifest'
        local def=ctx.getDef(talent)
        local expectsBuilder=entry.conformance and entry.conformance.builder
        if type(def)=='table' and def.target~=nil then
            local builder=def.target
            if type(builder)=='table' then
                typ=builder;builderSource='builder'
            elseif type(builder)=='function' then
                -- A throwing or non-table builder is a compatibility fault, not
                -- a reason to fall back to stale manifest geometry.
                local ok,value=pcall(builder,p,def)
                if not ok or type(value)~='table' then
                    return disable('adapter_builder_failed',{talent=talent,error=ok and 'non_table' or 'error'})
                end
                typ=value;builderSource='builder'
            else
                return disable('adapter_builder_failed',{talent=talent,error='non_callable'})
            end
        elseif expectsBuilder==true then
            return disable('adapter_builder_missing',{talent=talent})
        end
        local range=entry.range
        if typ and finite(typ.range) then range=typ.range end
        -- A range-0 self-centred effect (Flameshock's cone) is aimed by
        -- direction; the effect is centred on the caster, so the target distance
        -- does not bound it. Only positive ranges are distance-checked; the
        -- bound target is instead required to lie in the resolved instant
        -- footprint (checked after expansion).
        local range0=finite(range) and range==0
        if finite(range) and range>0 and Distance.grid(p.x,p.y,target.x,target.y)>range then
            return disable('target_out_of_range',{range=range,source=builderSource})
        end
        local probe_typ=typ or {type=entry.cursor and entry.cursor.shape,range=range,
            radius=entry.radius,talent=talent}
        -- A range-0 self-centred effect (Flameshock's cone) is aimed by direction
        -- and does not require the aim grid itself to be hittable; `canProject`
        -- would report the origin as the only hit and falsely deny it.
        if type(p.canProject)=='function' and not range0 then
            local ok,can=pcall(p.canProject,p,probe_typ,target.x,target.y)
            if not ok or can==nil then return disable('canproject_unknown',{source=builderSource}) end
            if can==false then return disable('no_line_of_sight',{source=builderSource}) end
        elseif type(p.canProject)~='function' and not range0 then
            return disable('canproject_unavailable')
        end
        -- Resolve every canonical component. Variants come only from audited
        -- scalar reads; an unresolved branch stays in the conservative union.
        local components={}
        local membershipsBy={}
        local instant_miss=false
        for _,component in ipairs(entry.components or {}) do
            if component.phase~='cursor' then
                local active=resolveWhen(component.when,providers)
                if active~=false then
                    local resolved={id=component.id,phase=component.phase,delivery=component.delivery,
                        shape=component.shape,range=component.range,radius=component.radius,
                        center=component.center,direction=component.direction,selffire=component.selffire,
                        friendlyfire=component.friendlyfire,player_selffire=component.player_selffire,
                        provenance=component.provenance,when=component.when,resolved_when=active,
                        builder_source=builderSource}
                    resolved.selffire=resolveDynamic(resolved.selffire,ctx,talent,def)
                    resolved.friendlyfire=resolveDynamic(resolved.friendlyfire,ctx,talent,def)
                    resolved.radius=resolveRadius(resolved.radius,typ)
                    -- The real builder supplies the instant/projectile geometry.
                    -- A field declared as an audited dynamic input is
                    -- authoritative: the raw builder value must never overwrite
                    -- an unknown/failed provider (an overridden method could
                    -- make the builder return 0 while the provider fails closed).
                    if typ and component.phase=='instant' then
                        if typ.type then resolved.shape=typ.type end
                        if finite(typ.range) then resolved.range=typ.range end
                        if finite(typ.radius) then resolved.radius=typ.radius end
                        if typ.selffire~=nil and not isDynamicInput(component.selffire) then resolved.selffire=typ.selffire end
                        if typ.friendlyfire~=nil and not isDynamicInput(component.friendlyfire) then resolved.friendlyfire=typ.friendlyfire end
                    end
                    local set,backend,tx,ty=footprintFor(resolved,ctx,target,typ)
                    resolved.footprint_backend=backend
                    components[#components+1]=resolved
                    if range0 and component.phase=='instant' and not Footprint.at(set,target.x,target.y) then
                        instant_miss=true
                    end
                    membershipsBy[resolved.id or resolved.phase]=memberships(resolved,set,ctx,typ)
                    membershipsBy[resolved.id or resolved.phase].tx=tx
                    membershipsBy[resolved.id or resolved.phase].ty=ty
                end
            end
        end
        -- A range-0 self-centred effect must still affect the bound target; the
        -- exact native instant footprint is the reachability predicate.
        if range0 and instant_miss then
            return disable('target_out_of_range',{range=range,talent=talent,
                reason='outside_instant_footprint',source=builderSource})
        end
        -- Melee already returned; a hostile entry with no effect component is a
        -- manifest fault, not a safe pass.
        if #components==0 then
            return disable('adapter_no_components',{talent=talent})
        end
        local measure=Risk.measure(components,membershipsBy)
        if measure.risk==0 then return nil end
        -- Q4: compare the measured known risk with the policy threshold. A
        -- known risk at or under the threshold is permitted (the detail is
        -- surfaced for the decision/log); above it, or an incalculable
        -- footprint, rejects this action. Built-in presets stay at 0.
        local worst=measure.detail
        local detail={risk=worst and worst.risk or nil,
            measurement=measure.risk,threshold=threshold,
            unknown=measure.risk=='unknown',talent=talent,source=builderSource}
        if worst then
            local resolvedComponent
            for _,component in ipairs(components) do
                if component.id==worst.component or component.phase==worst.phase then resolvedComponent=component end
            end
            detail.phase=worst.phase
            detail.component=worst.component
            detail.selffire=worst.selffire
            detail.friendlyfire=worst.friendlyfire
            detail.friendlies=worst.friendlies
            detail.explicit_override=resolvedComponent and resolvedComponent.builder_source=='builder' or false
            detail.provenance=worst.provenance or (resolvedComponent and resolvedComponent.provenance) or nil
            detail.footprint_backend=resolvedComponent and resolvedComponent.footprint_backend or nil
        end
        if measure.risk~='unknown' and type(measure.risk)=='number' and measure.risk<=threshold then
            return {action='permit',detail=detail}
        end
        return disable('selffire_risk',detail)
    end

    return guard
end

return M
