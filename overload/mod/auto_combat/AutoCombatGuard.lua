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
function M.footprintSpec(component,origin,bound)
    local tx,ty=bound.x,bound.y
    if component.direction~='target' and (component.center or 'target')=='self' then
        tx,ty=origin.x,origin.y
    end
    return {shape=component.shape,range=component.range,radius=component.radius,angle=component.angle,
        map_effect=component.delivery=='map_effect',
        origin={x=origin.x,y=origin.y},target={x=tx,y=ty}}
end

-- Union of footprints for the component list; a component whose condition is
-- unknown is included conservatively.
local function footprintFor(component,ctx,target)
    local p=ctx.source
    local spec=M.footprintSpec(component,p,target)
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

    -- Any integrity/uncertainty fault disables this action (the design's §8.1
    -- "disable that action" rule), leaving other complete actions eligible.
    local function disable(reason,detail)
        return {action='reject',reason=reason,detail=detail}
    end

    -- S3: the candidate envelope is bounded by the map dimensions; a radius
    -- beyond this plugin-own resource bound cannot be expanded honestly within
    -- one action opportunity, so it is unavailable (never invented).
    local CANDIDATE_RADIUS_CAP=16

    local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end

    -- Bounded map dimensions for the candidate enumeration (a plugin-own
    -- enumeration bound, never a strategy filter).
    local function bounds()
        local map=ctx.game and ctx.game.level and ctx.game.level.map
        if type(map)=='table' and finite(map.w) and finite(map.h)
            and map.w>0 and map.h>0 then return {w=map.w,h=map.h} end
        return nil
    end

    local function inBounds(cell,mapBounds)
        if not mapBounds then return false end
        return cell.x>=0 and cell.y>=0 and cell.x<mapBounds.w and cell.y<mapBounds.h
    end

    -- Every in-bounds integer cell within `radius` of `center`, in
    -- deterministic (y,x) order. Pure enumeration for repeatable evidence;
    -- never a tactical choice.
    local function circle(center,radius,mapBounds)
        local cells={}
        local rl=math.floor(radius)
        for dy=-rl,rl do
            for dx=-rl,rl do
                local cell={x=center.x+dx,y=center.y+dy}
                if Distance.grid(center.x,center.y,cell.x,cell.y)<=radius
                    and inBounds(cell,mapBounds) then
                    cells[#cells+1]=cell
                end
            end
        end
        return cells
    end

    -- S3 landing-candidate set (design §2.3). Returns the record
    -- `{kind,cells,center,radius}` or `nil, reason` where the reason is
    -- 'landing_envelope_unavailable' or (specifically: no plan and a
    -- `center='requested_grid'` descriptor) 'movement_plan_unavailable'.
    function M.landingCandidates(plan,entry,source,bound,mapBounds)
        local movement=type(entry)=='table' and entry.movement or {}
        local function fromLanding(landing)
            if type(landing)~='table' then return nil end
            if landing.kind=='deterministic' and type(landing.center)=='table'
                and finite(landing.center.x) and finite(landing.center.y) then
                local cell={x=landing.center.x,y=landing.center.y}
                if not inBounds(cell,mapBounds) then return nil,'out_of_bounds' end
                return {kind='deterministic',cells={cell},center=cell,radius=0}
            end
            if (landing.kind=='bounded' or landing.kind=='random')
                and type(landing.center)=='table' and finite(landing.center.x)
                and finite(landing.center.y) and finite(landing.radius) then
                if landing.radius>CANDIDATE_RADIUS_CAP then return nil,'unbounded' end
                local center={x=landing.center.x,y=landing.center.y}
                return {kind=landing.kind,cells=circle(center,landing.radius,mapBounds),
                    center=center,radius=landing.radius}
            end
            -- A random native choice without a resolved centre is anchored on
            -- the caster (the only player-known centre the plugin has).
            if landing.kind=='random' and finite(source.x) and finite(source.y)
                and finite(landing.radius) then
                if landing.radius>CANDIDATE_RADIUS_CAP then return nil,'unbounded' end
                local center={x=source.x,y=source.y}
                return {kind='random',cells=circle(center,landing.radius,mapBounds),
                    center=center,radius=landing.radius}
            end
            return nil
        end
        if type(plan)=='table' then
            local annotation=plan.annotation or {}
            if plan.kind=='grid' and finite(plan.x) and finite(plan.y)
                and (type(annotation.landing)~='table'
                    or annotation.landing.kind=='deterministic') then
                -- A deterministic landing: exactly the planned cell.
                local cell={x=plan.x,y=plan.y}
                if not inBounds(cell,mapBounds) then return nil,'out_of_bounds' end
                return {kind='deterministic',cells={cell},center=cell,radius=0}
            end
            local fromAnnotation=fromLanding(annotation.landing)
            if fromAnnotation then return fromAnnotation end
            if annotation.landing~=nil then return nil,'landing_envelope_unavailable' end
            -- A grid plan whose annotation could not be read falls back to the
            -- declared envelope around the requested grid (conservative).
            if plan.kind=='grid' and finite(plan.x) and finite(plan.y)
                and finite(movement.radius) and movement.radius<=CANDIDATE_RADIUS_CAP then
                local center={x=plan.x,y=plan.y}
                return {kind='bounded',cells=circle(center,movement.radius,mapBounds),
                    center=center,radius=movement.radius}
            end
        end
        -- No plan (or an unusable one): derive the envelope from the descriptor.
        local center=movement.center
        if center=='requested_grid' then return nil,'movement_plan_unavailable' end
        local anchor
        if center=='actor' then
            if not (finite(bound.x) and finite(bound.y)) then return nil,'landing_envelope_unavailable' end
            anchor={x=bound.x,y=bound.y}
        else
            anchor={x=source.x,y=source.y}
            if not (finite(anchor.x) and finite(anchor.y)) then return nil,'landing_envelope_unavailable' end
        end
        local radius=movement.radius
        if not finite(radius) or radius>CANDIDATE_RADIUS_CAP then
            return nil,'landing_envelope_unavailable'
        end
        return {kind='bounded',cells=circle(anchor,radius,mapBounds),center=anchor,radius=radius}
    end

    -- Resolve ONE candidate against a `landing_adjacent` condition (exported
    -- pure for tests): the component is active only when the mover's FINAL
    -- cell is at distance 1 from the named anchor. An unreadable anchor is
    -- 'unknown' (fail closed), never silently dropped.
    function M.candidateCondition(when,cell,anchor)
        if when==nil or when.kind==nil or when.kind=='always' then return true end
        if when.kind~='landing_adjacent' or when.anchor~='actor' then return 'unknown' end
        if type(anchor)~='table' or not finite(anchor.x) or not finite(anchor.y) then
            return 'unknown'
        end
        return Distance.grid(cell.x,cell.y,anchor.x,anchor.y)==1
    end

    -- Aggregate a candidate-aware `landing_adjacent` condition over the whole
    -- candidate set: `true` when any candidate may satisfy it (conservative),
    -- `false` when none can, 'unknown' when the anchor itself is unreadable.
    local function resolveAdjacentCondition(when,candidates,anchor)
        if when==nil or when.kind==nil or when.kind=='always' then return true end
        local unknown=false
        for _,cell in ipairs(candidates.cells or {}) do
            local value=M.candidateCondition(when,cell,anchor)
            if value==true then return true end
            if value=='unknown' then unknown=true end
        end
        if unknown then return 'unknown' end
        return false
    end

    -- S3 D1: the COMPLETE component x landing-candidate expansion (never the
    -- analytic circle). For every applicable (component, candidate) pair the
    -- exact footprint spec is expanded through the existing backend; the union
    -- is kept ONLY when every required pair succeeded. One nil/malformed/failed
    -- expansion discards the partial union (D1) and the component becomes
    -- unknown — a partial union is never measured. `bound` is the resolved
    -- bound hostile (the landing_adjacent anchor and the normal target centre).
    local function expandComplete(component,candidates,boundHostile,radius,raised,opts)
        local required=0
        local completed=0
        local union=nil
        local unionAdd=nil
        local backends={}
        local failure
        local unknown
        for _,cell in ipairs(candidates.cells) do
            local condValue=M.candidateCondition(component.when,cell,boundHostile)
            if condValue==false then
                -- The pair is not applicable; no expansion is required.
            elseif condValue=='unknown' then
                -- An unknown relation/anchor makes the WHOLE component result
                -- unknown; it is never silently dropped.
                failure='condition_unknown'
                break
            else
                local spec=M.footprintSpec(component,cell,boundHostile)
                spec.radius=radius
                if component.center=='actual_landing' then
                    -- The candidate is both the post-move source and the
                    -- effect center; the native backend starts the line at the
                    -- mover's post-move cell.
                    spec.origin={x=cell.x,y=cell.y}
                    spec.target={x=cell.x,y=cell.y}
                    spec.start_x=cell.x;spec.start_y=cell.y
                end
                -- D3: the real raised spec's projection flags are copied into
                -- the footprint spec before native expansion (raw presence
                -- preserved; Target:getType normalizes absent
                -- selffire/friendlyfire to true).
                for flag,value in pairs(raised or {}) do
                    spec[flag]=value
                end
                required=required+1
                -- The expander is injectable for failure-injection tests (the
                -- production path is always the audited Footprint.expand).
                local expander=(opts and opts.expand) or Footprint.expand
                local set,backend=expander(spec,{native=ctx.native,
                    blockPath=ctx.blockPath,blockRadius=ctx.blockRadius})
                backends[backend]=true
                if set==nil then
                    failure=backend or 'expand_failed'
                    break
                end
                completed=completed+1
                if union==nil then union,unionAdd=Footprint.newSet() end
                for x,column in pairs(set) do
                    for y in pairs(column) do unionAdd(x,y) end
                end
            end
        end
        if failure then
            return nil,{failure=failure,required=required,completed=completed,
                backend=next(backends) or (ctx.native and 'native' or 'model')}
        end
        return union,{required=required,completed=completed,backend=next(backends)
            or (ctx.native and 'native' or 'model'),
            multi=(backends.native and backends.model) and true or nil}
    end
    M.expandComplete=expandComplete  -- exported pure (test seam: injectable expander)

    -- S3 mixed-entry composition. `typ` is the real raised spec (raw table)
    -- already read by the shared prelude; `builderSource` records where the
    -- raised spec came from. Commit-1 scope: DIRECT bound-actor components
    -- (`delivery='attackTarget'`) are validated, evidenced and left risk-exempt;
    -- the candidate envelope is enumerated; projected (actual_landing)
    -- components are expanded in the Giant Leap commit.
    local function mixedComposition(entry,attempt,typ,builderSource,target,talent,threshold)
        local mapBounds=bounds()
        local plan=attempt.plan
        local candidates,envReason=M.landingCandidates(plan,entry,p,target,mapBounds)
        if not candidates then
            if envReason=='movement_plan_unavailable' then
                return disable('movement_plan_unavailable',{talent=talent})
            end
            return disable('selffire_risk',{unknown=true,talent=talent,
                reason=envReason or 'landing_envelope_unavailable'})
        end
        local components={}
        local membershipsBy={}
        local componentsEvaluated=0
        local candidateCount=#candidates.cells
        for _,component in ipairs(entry.components) do
            local resolved={id=component.id,phase=component.phase,delivery=component.delivery,
                shape=component.shape,center=component.center,radius=component.radius,
                when=component.when,provenance=component.provenance,
                candidate_count=candidateCount,builder_source=builderSource}
            if component.delivery=='attackTarget' then
                -- D2: a direct, already-bound actor effect keeps the existing
                -- closed `attackTarget` token. Its center must resolve to the
                -- bound hostile; it is recorded in evidence and never expanded
                -- (no ActorProject footprint exists and EffectRisk intentionally
                -- exempts the class).
                componentsEvaluated=componentsEvaluated+1
                if component.center=='actor' or component.center=='target' then
                    if not (finite(target.x) and finite(target.y)) then
                        return disable('target_geometry_unknown',{talent=talent,
                            component=resolved.id})
                    end
                else
                    return disable('target_geometry_unknown',{talent=talent,
                        component=resolved.id,
                        reason='direct_component_center_unboundable'})
                end
                resolved.required_expansions=0
                resolved.completed_expansions=0
                resolved.footprint_count=0
                resolved.condition=component.when
                resolved.resolved_condition=resolveAdjacentCondition(component.when,
                    candidates,target)
                -- Direct bound-hostile components contribute zero self/friendly
                -- risk but stay declared (they are never invisible).
                membershipsBy[resolved.id]={self=false,friendlies=0,player_override=true}
            else
                -- Projected / actual_landing component: the COMPLETE per-pair
                -- expansion (D1). The component radius may be the live builder
                -- radius (`{from='target'}`); an unreadable radius is unknown
                -- and fails closed. The raised projection flags (D3) come from
                -- the real raised spec.
                componentsEvaluated=componentsEvaluated+1
                local radius=resolveRadius(component.radius,typ)
                resolved.radius=radius
                -- Curated static filters resolve through the audited dynamic
                -- input providers (an unavailable dynamic read stays unknown
                -- and fails closed on its own value).
                resolved.selffire=resolveDynamic(component.selffire,ctx,talent,
                    ctx.getDef(talent))
                resolved.friendlyfire=resolveDynamic(component.friendlyfire,ctx,talent,
                    ctx.getDef(talent))
                resolved.player_selffire=component.player_selffire
                if radius=='unknown' then
                    return disable('selffire_risk',{unknown=true,talent=talent,
                        component=resolved.id,reason='unreadable_radius'})
                end
                -- D3 raised projection flags: raw presence map from the real
                -- raised spec (only explicitly present keys; absent keys stay
                -- absent and Target:getType normalizes them at expansion time).
                local raised={}
                local raisedCount=0
                for flag in pairs({friendlyblock=true,friendlyfire=true,selffire=true,
                    pass_terrain=true,no_restrict=true,actorblock=true,stop_block=true}) do
                    if type(typ)=='table' and typ[flag]~=nil then
                        raised[flag]=typ[flag]
                        raisedCount=raisedCount+1
                    end
                end
                if raisedCount>0 then resolved.raised_flags=raised end
                local union,stats=expandComplete(component,candidates,target,radius,
                    raisedCount>0 and raised or nil)
                resolved.condition=component.when
                if not union then
                    -- D1: one failed/unreadable pair discards the partial
                    -- union; membership is unknown and this action is disabled
                    -- (never measured, never silently dropped).
                    return disable('selffire_risk',{unknown=true,talent=talent,
                        component=resolved.id,reason=stats.failure,
                        required_expansions=stats.required,
                        completed_expansions=stats.completed,
                        footprint_backend=stats.backend})
                end
                -- Complete-expansion bookkeeping; the completed count is
                -- asserted before any membership/risk calculation.
                resolved.required_expansions=stats.required
                resolved.completed_expansions=stats.completed
                resolved.candidate_count=candidateCount
                resolved.footprint_count=Footprint.count(union)
                resolved.footprint_backend=stats.multi and 'mixed' or stats.backend
                if stats.completed~=stats.required then
                    return disable('selffire_risk',{unknown=true,talent=talent,
                        component=resolved.id,reason='incomplete_expansion',
                        required_expansions=stats.required,
                        completed_expansions=stats.completed})
                end
                -- Post-move self membership (design §5.1 corrected): for an
                -- `actual_landing` component the mover is affected when ANY
                -- completed per-candidate footprint contains that same
                -- candidate — never the caster's pre-move cell (which the
                -- generic membership helper tests and which we override).
                if component.center=='actual_landing' then
                    local m=memberships(resolved,union,ctx,typ)
                    local selfSelf=false
                    for _,cell in ipairs(candidates.cells) do
                        if M.candidateCondition(component.when,cell,target)
                            and Footprint.at(union,cell.x,cell.y) then
                            selfSelf=true
                        end
                    end
                    m.self=selfSelf
                    resolved.self_excluded=(selfSelf and Risk.flag(resolved.selffire)==0)
                        or nil
                    membershipsBy[resolved.id]=m
                else
                    -- A projected component with a normal centre keeps the
                    -- existing membership semantics against its own union.
                    membershipsBy[resolved.id]=memberships(resolved,union,ctx,typ)
                end
            end
            components[#components+1]=resolved
        end
        if componentsEvaluated==0 then
            return disable('adapter_no_components',{talent=talent})
        end
        -- Measure only after every non-exempt component union is complete.
        local measure=Risk.measure(components,membershipsBy)
        local detail={talent=talent,source=builderSource,candidate_count=candidateCount,
            components_evaluated=componentsEvaluated,threshold=threshold,
            unknown=measure.risk=='unknown',components=components}
        if measure.risk~=0 then
            local worst=measure.detail
            if worst then
                detail.risk=worst.risk
                detail.measurement=measure.risk
                detail.phase=worst.phase
                detail.component=worst.component
                detail.selffire=worst.selffire
                detail.friendlyfire=worst.friendlyfire
                detail.friendlies=worst.friendlies
                detail.provenance=worst.provenance or nil
                detail.footprint_backend=worst.footprint_backend
            end
            if measure.risk~='unknown' and type(measure.risk)=='number'
                and measure.risk<=threshold then
                return {action='permit',detail=detail}
            end
            return disable('selffire_risk',detail)
        end
        -- A zero-risk mixed entry still publishes its composition evidence so
        -- the decision trace shows the complete evaluation (never invisible).
        detail.measurement=0
        return {action='permit',detail=detail}
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
        -- Movement adapters carry no damage footprint; their landing/uncertainty
        -- safety is the MovementPlanner's explicit policy acceptance. A MIXED
        -- movement entry (S3) falls through to the composition path below; a
        -- component-free movement entry is still skipped.
        local isMovement=entry.kind=='movement'
        local isMixed=isMovement and #(entry.components or {})>0
        if isMovement then
            if not isMixed then return nil end
        elseif entry.target~='hostile' then
            return nil
        end
        local target
        if attempt.bound_target then target=ctx.resolve(attempt.bound_target) end
        if not target then return disable('target_lost') end
        if not (finite(target.x) and finite(target.y) and finite(p.x) and finite(p.y)) then
            return disable('target_geometry_unknown')
        end
        -- Melee delivery never consults ActorProject filters. The entry-level
        -- shortcut is not taken for a mixed entry: exemption is component-local
        -- (EffectRisk), never entry-level.
        if entry.melee and not isMixed then return nil end
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
        -- S3: a mixed movement entry takes the composition path before any
        -- hostile component loop; the plan is passed through unmodified.
        if isMixed then
            return mixedComposition(entry,attempt,typ,builderSource,target,talent,threshold)
        end
        -- Resolve every canonical component. Variants come only from audited
        -- scalar reads; an unresolved branch stays in the conservative union.
        local components={}
        local membershipsBy={}
        local instant_miss=false
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
                    local set,backend,tx,ty=footprintFor(resolved,ctx,target)
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
