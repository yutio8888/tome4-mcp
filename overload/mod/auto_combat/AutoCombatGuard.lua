-- GPL-3.0-or-later. Manifest-driven pre-execution safety guard (v2).
--
-- For a selected hostile action this module:
--   1. requires the version-pinned manifest entry and a source-drift pass;
--   2. resolves each canonical component's declarative condition from audited
--      scalar reads (a branch that cannot be resolved is kept, producing the
--      conservative union);
--   3. expands the exact footprint of every active component (native backend
--      when the engine geometry is present, pure model otherwise);
--   4. composes self/friendly risk per delivery path and applies the frozen
--      `max_selffire_risk` policy (0 rejects, >0 pauses; never authorises a
--      percentage).
--
-- It returns nil to permit the native executor, or a verdict table
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

-- Union of footprints for the component list; a component whose condition is
-- unknown is included conservatively.
local function footprintFor(component,ctx,target)
    local p=ctx.source
    local center=component.center or 'target'
    local tx,ty=target.x,target.y
    if center=='self' then tx,ty=p.x,p.y end
    local spec={shape=component.shape,range=component.range,radius=component.radius,
        origin={x=p.x,y=p.y},target={x=tx,y=ty}}
    local set,backend=Footprint.expand(spec,{native=ctx.native,blockPath=ctx.blockPath,
        blockRadius=ctx.blockRadius})
    return set,backend,tx,ty
end

local function memberships(component,set,ctx)
    local p=ctx.source
    local m={}
    if set==nil then return {self='unknown',friendlies='unknown'} end
    m.self=Footprint.at(set,p.x,p.y) and true or false
    local ff=Risk.flag(component.friendlyfire)
    if ff==0 then
        m.friendlies=0
        return m
    end
    local count=0
    local unknown=false
    local seen={}
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

local function playerOverride(component,typ,ctx)
    if component.delivery~='projectile' then return true end
    if component.player_selffire==false then return false end
    if component.player_selffire==true then return true end
    return ctx.details.playerSelfOverride(ctx.source,typ or {})
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

    local function verdict(hard,reason,detail)
        return {action=hard and 'reject' or 'pause',reason=reason,detail=detail}
    end

    local function guard(attempt)
        local action=attempt.action
        if action~='attack' and action~='use_talent' then return nil end
        if not p then return {action='reject',reason='actor_unavailable'} end
        local talent=action=='attack' and 'T_ATTACK' or attempt.talent
        local entry=Manifest.entry(talent)
        if not entry then return {action='reject',reason='unsupported_adapter'} end
        local policy=ctx.policy
        local maxRisk=policy and policy.safety and policy.safety.max_selffire_risk
        local hard=(maxRisk==nil or maxRisk<=0)
        if entry.target~='hostile' then return nil end
        -- Source drift disables the adapter; stale metadata is never used.
        local driftOk,driftReason,driftDetail=ctx.drift()
        if driftOk~=true then
            return verdict(hard,'adapter_source_drift',{reason=driftReason,detail=driftDetail})
        end
        local target
        if attempt.bound_target then target=ctx.resolve(attempt.bound_target) end
        if not target then return verdict(hard,'target_lost') end
        if not (finite(target.x) and finite(target.y) and finite(p.x) and finite(p.y)) then
            return verdict(hard,'target_geometry_unknown')
        end
        -- Melee delivery never consults ActorProject filters.
        if entry.melee then return nil end
        -- Real target spec from the audited native builder when available; the
        -- manifest remains the canonical source for secondary/ground/variants.
        local typ,builderSource=nil,'manifest'
        local def=ctx.getDef(talent)
        if type(def)=='table' then
            local builder=def.target
            if type(builder)=='table' then typ=builder;builderSource='builder'
            elseif type(builder)=='function' then
                local ok,value=pcall(builder,p,def)
                if ok and type(value)=='table' then typ=value;builderSource='builder' end
            end
        end
        local range=entry.range
        if typ and finite(typ.range) then range=typ.range end
        if finite(range) and Distance.grid(p.x,p.y,target.x,target.y)>range then
            return verdict(hard,'target_out_of_range',{range=range,source=builderSource})
        end
        local probe_typ=typ or {type=entry.cursor and entry.cursor.shape,range=range,
            radius=entry.radius,talent=talent}
        if type(p.canProject)=='function' then
            local ok,can=pcall(p.canProject,p,probe_typ,target.x,target.y)
            if not ok or can==nil then return verdict(hard,'canproject_unknown',{source=builderSource}) end
            if can==false then return verdict(hard,'no_line_of_sight',{source=builderSource}) end
        else
            return verdict(hard,'canproject_unavailable')
        end
        -- Resolve every canonical component. Variants come only from audited
        -- scalar reads; an unresolved branch stays in the conservative union.
        local components={}
        local membershipsBy={}
        local providers={
            talentLevel=function()
                local level=p.talents and p.talents[talent]
                return finite(level) and level or nil
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
                        center=component.center,selffire=component.selffire,
                        friendlyfire=component.friendlyfire,player_selffire=component.player_selffire,
                        provenance=component.provenance,when=component.when,resolved_when=active,
                        builder_source=builderSource}
                    -- The real builder supplies the instant/projectile geometry.
                    if typ and component.phase=='instant' then
                        if typ.type then resolved.shape=typ.type end
                        if finite(typ.range) then resolved.range=typ.range end
                        if finite(typ.radius) then resolved.radius=typ.radius end
                        if typ.selffire~=nil then resolved.selffire=typ.selffire end
                        if typ.friendlyfire~=nil then resolved.friendlyfire=typ.friendlyfire end
                    end
                    local set,backend,tx,ty=footprintFor(resolved,ctx,target)
                    resolved.footprint_backend=backend
                    components[#components+1]=resolved
                    membershipsBy[resolved.id or resolved.phase]=memberships(resolved,set,ctx)
                    membershipsBy[resolved.id or resolved.phase].tx=tx
                    membershipsBy[resolved.id or resolved.phase].ty=ty
                end
            end
        end
        -- Melee already returned; a hostile entry with no effect component is a
        -- manifest fault, not a safe pass.
        if #components==0 then
            return verdict(hard,'adapter_no_components',{talent=talent})
        end
        local safe,detail=Risk.evaluate(components,membershipsBy)
        if safe then return nil end
        local resolvedComponent
        for _,component in ipairs(components) do
            if component.id==detail.component or component.phase==detail.phase then resolvedComponent=component end
        end
        detail.talent=talent
        detail.source=builderSource
        detail.explicit_override=resolvedComponent and resolvedComponent.builder_source=='builder' or false
        detail.provenance=resolvedComponent and resolvedComponent.provenance or nil
        return verdict(hard,'selffire_risk',detail)
    end

    return guard
end

return M
