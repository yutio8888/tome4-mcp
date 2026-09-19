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

-- R2-APR2-03: the EXACT set of engine-consulted STATIC projection fields the
-- guard forwards from the REAL raised spec. `ActorProject:project` (and the
-- `Target:getType`/`Target.block_path`/`Target.block_radius` helpers it calls)
-- consults all of these when building the grid set, so dropping any of them can
-- silently change the measured footprint:
--   * `selffire`/`friendlyfire` filter the affected actors
--     (ActorProject.lua:248-255,493-494); `selffire`/`friendlyfire` and
--     `player_selffire` are also mirrored into risk modelling;
--   * `stop_block`/`actorblock`/`friendlyblock` decide entity blocking in
--     `Target.block_path` (Target.lua:490-555,564-610);
--   * `nolock`/`pass_terrain`/`nowarning`/`no_restrict`/`requires_knowledge`
--     are the default blocker's terrain/knowledge switches
--     (Target.lua:652-695);
--   * `force_max_range` controls the line iterator's stepping
--     (ActorProject.lua:78,113-114,307,331-332);
--   * `min_range` can EMPTY the result and `grid_exclude` can remove grids
--     (ActorProject.lua:226-239);
--   * `act_exclude` (`{[uid]=true,...}`, R2-APR3-01) is engine-consulted:
--     documented at Target.lua:647-650 and applied BEFORE the self/friendly
--     admission (ActorProject.lua:248-255), so any actor whose uid is a key —
--     INCLUDING the caster — is not hit; the membership measurement honours it
--     (see `memberships`). Presence is table-valued: a raised table is
--     forwarded verbatim and an explicit `[uid]=false` stays a non-exclusion;
--   * `filter` removes grids (ActorProject.lua:59-63);
--   * a raised `block_path`/`block_radius` callback (or an explicit `false`)
--     REPLACES the default blocker (ActorProject.lua:78-80,113-114,226-239 —
--     `if typ.block_path then` is false for `false`, so the default is disabled).
-- R2-APR3-02 (checklist B): the engine INVOKES `block_path`, `block_radius`
-- and `filter` as functions (ActorProject.lua:60,74,95-96 and the radial
-- `typ:block_radius` calls). A non-nil, non-function value of those fields can
-- never be honoured and must never be forwarded (the engine would call it and
-- error); `M.malformedFunctionField` reports it so the guard turns it into an
-- explicit unknown -> fail-closed rejection BEFORE any expansion.
-- `getType` fills these only as DEFAULTS and `table.update` never overwrites a
-- raised field, including a boolean `false` (engine/utils.lua:559-569), so a
-- value is forwarded when it is present (`~=nil`, which admits `false`).
-- NOT forwarded here: the per-projection instance fields the caller sets
-- (`source_actor`, `start_x`/`start_y`, `x`/`y`, `line_function`, `bypass`,
-- `multiple`) and the shape/radius geometry the guard derives from the
-- manifest component; `Target.getType` supplies those itself.
local FOOTPRINT_FLAGS={'friendlyblock','friendlyfire','nolock','pass_terrain',
    'nowarning','no_restrict','requires_knowledge','selffire','actorblock',
    'stop_block','force_max_range','min_range','grid_exclude','filter',
    'block_path','block_radius','act_exclude'}
-- The function-valued raised fields (engine-meaningful explicit `false`
-- included, which disables the default blocker/filter like a raised `false`
-- does for `block_path`).
local FUNCTION_FIELDS={block_path=true,block_radius=true,filter=true}

-- R2-APR3-02: the name of a raised function-valued field whose value is a
-- non-nil, non-function, non-`false` (string/number/boolean/...): the engine
-- would invoke it and the footprint is not measurable. A real function and an
-- explicit `false` are valid and are forwarded verbatim.
function M.malformedFunctionField(flags)
    if type(flags)~='table' then return nil end
    for key in pairs(FUNCTION_FIELDS) do
        local value=flags[key]
        if value~=nil and value~=false and type(value)~='function' then return key end
    end
    return nil
end

function M.copyFootprintFlags(spec,flags)
    if type(flags)~='table' then return spec end
    for _,key in ipairs(FOOTPRINT_FLAGS) do
        if flags[key]~=nil then
            -- R2-APR3-02: a malformed function-valued field is NEVER forwarded
            -- (the caller fails closed through `M.malformedFunctionField`); a
            -- real callback and an explicit `false` are forwarded verbatim.
            if FUNCTION_FIELDS[key] and type(flags[key])~='function'
                and flags[key]~=false then
                -- skip: explicit unknown -> fail closed upstream
            else
                spec[key]=flags[key]
            end
        end
    end
    return spec
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
    -- rebuilt from geometry alone can manufacture a false blocked line. The
    -- complete engine-consulted allowlist (R2-APR2-03) is forwarded verbatim.
    M.copyFootprintFlags(spec,flags)
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
    -- R2-APR3-01: the engine admits actors against `typ.act_exclude` BEFORE the
    -- self/friendly-fire filters (ActorProject.lua:248-255, documented at
    -- Target.lua:647-650): an actor whose uid is a key of the raised table —
    -- INCLUDING the caster — is never hit. The measurement mirrors that
    -- admission. A raised non-table `act_exclude`, or an actor whose uid is
    -- unreadable while a raised `act_exclude` is present, makes the engine
    -- admission undecidable: the membership is unknown (conservative union,
    -- fail closed). An explicit `[uid]=false` stays a non-exclusion.
    local actExclude=(typ~=nil and type(typ)=='table') and typ.act_exclude or nil
    local function actExcluded(actor)
        if actExclude==nil then return false end
        if type(actExclude)~='table' then return nil end
        local uid=type(actor)=='table' and actor.uid or nil
        if uid==nil then return nil end
        return actExclude[uid] and true or false
    end
    local selfExcluded=actExcluded(p)
    if selfExcluded==nil then
        m.self='unknown'
    else
        m.self=(not selfExcluded) and Footprint.at(set,p.x,p.y) and true or false
    end
    local ff=Risk.flag(component.friendlyfire)
    if ff==0 then
        m.friendlies=0
        return m
    end
    local count=0
    local unknown=false
    for _,ally in ipairs(ctx.allies() or {}) do
        if finite(ally.x) and finite(ally.y) then
            local excluded=actExcluded(ally)
            if excluded==nil then unknown=true
            elseif not excluded and Footprint.at(set,ally.x,ally.y) then count=count+1 end
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
        -- The curated copy IS the real local `tg` table of these talents, so the
        -- same engine-consulted allowlist is forwarded (R2-APR2-03).
        M.copyFootprintFlags(spec,curated)
        return spec
    end

    -- R2-APR-02: the ONLY stationary routing input is the template-derived
    -- marker the factory sets on a resolved `stationary_sequence` leaf, AND the
    -- leaf's fixed stationary delivery. The factory refuses a caller-authored
    -- `delivery='stationary'` (or `landing/center='none'`) on every other
    -- template at build time, so this conjunction can never be produced by a
    -- raw caller-authored enum: a mover leaf, an entry-level forged boolean or
    -- a marker-less stationary enum all stay on the ordinary movement skip.
    local function isStationaryLeaf(movement)
        return type(movement)=='table' and movement.stationary==true
            and movement.delivery=='stationary'
    end

    -- A′ §6.5: stationary guard routing is a VALIDATED CONSEQUENCE of the
    -- resolved movement template, never an independent manifest boolean. A
    -- factory leaf can only carry `delivery='stationary'` when it came from the
    -- closed `stationary_sequence` template (its `delivery`/`landing`/`center`
    -- are fixed invariants a caller cannot supply, and the reserved values are
    -- refused on every other template — R2-APR-02), so the declared leaves are
    -- mechanical data keyed on the template-derived marker
    -- (`isStationaryLeaf`). The resolved leaf then decides the route: a
    -- stationary leaf runs the stationary measurement; a mover leaf keeps the
    -- ordinary movement skip; an unresolvable variant fails closed.
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
                leaves[#leaves+1]=isStationaryLeaf(variant.movement)
            end
        else
            leaves[1]=isStationaryLeaf(movement)
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
        return isStationaryLeaf(resolved) end

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
    --   * the plan is a DENSE array over ALL keys (R2-APR-01): any non-integer
    --     key, hole or trailing gap is a typed `movement_plan_unavailable`
    --     BEFORE any precheck/expansion — `ipairs`-style iteration would
    --     silently truncate a sparse plan into a complete-looking one;
    --   * the plan carries EXACTLY ONE grid per entry of the planner-attached
    --     RESOLVED request sequence (R2-APR2-01: the resolved sequence is
    --     REQUIRED and is DENSE-validated over all keys, then compared
    --     entry-by-entry on kind — an absent or sparse attached sequence is a
    --     typed `movement_plan_unavailable` before any measurement, so it can
    --     never "match any variant length") — never a measured risk from a
    --     partial set;
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
        -- R2-APR-01: dense-array validation over ALL keys BEFORE any
        -- precheck/expansion. A sparse plan (valid grids at keys 1 and 3) is
        -- never measured as a complete one-grid plan.
        local denseOk,planCause=Factory.validateArray(plan.values,1)
        local planLength=denseOk and planCause or nil
        if not denseOk then
            return disable('movement_plan_unavailable',{talent=talent,
                reason='a stationary program needs a dense planned grid array',
                detail='bad_plan_shape',cause=planCause})
        end
        -- R2-APR-01/R2-APR2-01: the resolved request-sequence is REQUIRED and
        -- cross-checked BEFORE any precheck/expansion. The planner attaches the
        -- RESOLVED sequence (`MovementPlanner.planSequence`), so a stationary
        -- plan always carries it; an ABSENT sequence is `movement_plan_unavailable`
        -- (an absent sequence must never "match any variant length", which is
        -- exactly how a one-grid partial measurement could slip through). The
        -- attached sequence is DENSE-validated over ALL keys first — Lua `#`
        -- reports 1 for keys {1,3}, so a `#`-based length check is forgeable
        -- (the reviewer's SPARSE_DECLARED_BYPASS). Only after the shape is dense
        -- is its length used, and the length is then cross-checked AND compared
        -- entry-by-entry (kind) against the planned values.
        local declared=plan.request_sequence
        if declared==nil then
            return disable('movement_plan_unavailable',{talent=talent,
                reason='a stationary program needs its resolved request sequence',
                detail='plan_sequence_missing',got=planLength})
        end
        local seqOk,seqLengthOrCause=Factory.validateArray(declared,1)
        if not seqOk then
            return disable('movement_plan_unavailable',{talent=talent,
                reason='a stationary program needs a dense resolved request sequence',
                detail='bad_plan_shape',cause=seqLengthOrCause})
        end
        local declaredLength=seqLengthOrCause
        if declaredLength~=planLength then
            return disable('movement_plan_unavailable',{talent=talent,
                reason='a stationary plan must have one grid per declared entry',
                detail='plan_sequence_length_mismatch',declared=declaredLength,
                got=planLength})
        end
        -- The attached sequence length must also be one of the entry's DECLARED
        -- executable program lengths (a pure manifest read — no runtime scalar,
        -- so an unresolved variant matrix cannot weaken it). A caller-supplied
        -- plan cannot invent a program length the descriptor never declared.
        local matchedLength=false
        for _,sequence in ipairs(Manifest.requestSequences(entry) or {}) do
            local seqShape,seqLen=Factory.validateArray(sequence,1)
            if seqShape and seqLen==declaredLength then matchedLength=true end
        end
        if not matchedLength then
            return disable('movement_plan_unavailable',{talent=talent,
                reason='a stationary plan must have one grid per declared entry',
                detail='plan_sequence_length_mismatch',declared=declaredLength,
                got=planLength})
        end
        for index=1,declaredLength do
            local entry=declared[index]
            local kind=type(entry)=='table' and (entry.request or entry.kind) or nil
            local value=plan.values[index]
            local valueKind=type(value)=='table' and (value.request or value.kind) or nil
            if kind==nil or valueKind==nil or kind~=valueKind then
                return disable('movement_plan_unavailable',{talent=talent,
                    reason='a stationary plan must match its resolved request sequence',
                    detail='plan_sequence_kind_mismatch',index=index,
                    declared=kind,got=valueKind})
            end
        end
        local grids={}
        for index=1,planLength do
            local value=plan.values[index]
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
        -- R2-APR3-02 (checklist B): the curated static flags ARE the raised
        -- spec here; a malformed function-valued field is an explicit unknown
        -- -> fail closed BEFORE any precheck/expansion (the engine would
        -- invoke the non-function value).
        local malformedField=M.malformedFunctionField(stationaryProbeSpec(entry,talent,range))
        if malformedField then
            return disable('selffire_risk',{talent=talent,stationary=true,
                unknown=true,reason='malformed_function_field',field=malformedField})
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
                            talent=talent,
                            origin={x=origin.x,y=origin.y},target={x=grid.x,y=grid.y}}
                        -- R2-APR2-03: the SAME engine-consulted allowlist reaches
                        -- the stationary footprint input, including an explicit
                        -- `false` (which the engine honours).
                        M.copyFootprintFlags(spec,flags)
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
        -- R2-APR3-02 (checklist B): the engine INVOKES `block_path`,
        -- `block_radius` and `filter` as functions (ActorProject.lua:60,74,95-96
        -- and the radial `typ:block_radius` calls). A raised non-nil
        -- non-function value of those fields is never forwarded; it is an
        -- explicit unknown -> fail closed BEFORE any precheck/expansion.
        local malformedField=typ and M.malformedFunctionField(typ) or nil
        if malformedField then
            return disable('selffire_risk',{talent=talent,unknown=true,
                reason='malformed_function_field',field=malformedField,
                source=builderSource})
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
