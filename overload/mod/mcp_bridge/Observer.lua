-- GPL-3.0-or-later. Scalar reads and native perception caches only.
local Json = require 'mod.mcp_bridge.Json'
local Actions = require 'mod.mcp_bridge.Actions'
local Details = require 'mod.mcp_bridge.ObservationDetails'
local Progression = require 'mod.mcp_bridge.Progression'
local Items = require 'mod.mcp_bridge.Items'
local Compat = require 'mod.mcp_bridge.NativeCompatibility'
local Distance = require 'mod.mcp_bridge.Distance'
local ActorCombat = require 'mod.mcp_bridge.ActorCombat'
local M = {}
local memories = setmetatable({}, {__mode='k'})
local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end
local function number(n) return finite(n) and n or nil end
local function active(v) return v~=nil and v~=false and v~=0 end
local function grid(t, map, x, y) return t and t[x+y*map.w] end
local function wildernessVision(g,p,map)
    -- The audited wilderness branch skips ESP/detection and applies light only
    -- to native FOV cells. Never substitute has_seens/remembers/all_lited here:
    -- they also include old knowledge and cells outside current perception.
    return g.zone and g.zone.wilderness==true
        and Compat.matches('playerFOV',p.playerFOV)
        and Compat.matches('computeFOV',p.computeFOV)
        and Compat.matches('map.applyLite',map.applyLite)
        and Compat.matches('map.cleanFOV',map.cleanFOV)
end
local function native(fn,suffix)
    if type(fn)~='function' then return false end
    local info=debug.getinfo(fn,'S')
    return info and type(info.source)=='string' and info.source:sub(1,1)=='@'
        and info.source:sub(-#suffix)==suffix
end
function M.reset() memories=setmetatable({}, {__mode='k'}) end
-- The exact terrain-visibility predicate used by the window capture: FOV plus
-- the light/actor guard, with the audited wilderness branch. Shared so the
-- full-level map cannot drift from the window.
function M.terrainVisible(g,p,map,x,y)
    if not p or not map or not finite(x) or not finite(y) then return false end
    if not active(grid(map.seens,map,x,y)) or active(p.blind) then return false end
    if wildernessVision(g,p,map) then return true end
    if not grid(map.infovs,map,x,y) then return false end
    local cell=map.map and map.map[x+y*map.w]
    local actor=cell and cell[map.ACTOR or 3]
    return (not actor or actor==p or active(grid(map.lites,map,x,y))) and true or false
end
function M.actorId(meta, actor)
    return meta.session_id..':'..meta.level_instance_id..':actor-'..tostring(actor.uid)
end
function M.visible(g, actor)
    local p, map = g.player, g.level and g.level.map
    if not p or not map or not actor or actor.dead or not finite(actor.x) or not finite(actor.y) then return false end
    if actor==p then return true end
    local cell=map.map and map.map[actor.x+actor.y*map.w]
    if not cell or cell[map.ACTOR or 3]~=actor then return false end
    if not grid(map.seens,map,actor.x,actor.y) then return false end
    local seen = p.can_see_cache and p.can_see_cache[actor]
    seen = seen and seen['nil/nil']
    if seen then return seen[1]==true end
    -- Actor:act clears its seeing cache even when stationary map objects are
    -- not rebuilt. The native ordinary-vision branch is deterministic when
    -- none of the four special conditions applies. Audit every method used
    -- by that branch, then read its scalar inputs without invoking callbacks.
    if not native(p.canSee,'/mod/class/Actor.lua') or not native(p.canSeeNoCache,'/mod/class/Actor.lua')
        or not native(p.attr,'/engine/Entity.lua') or not native(actor.attr,'/engine/Entity.lua') then return false end
    if active(p.blind) or active(actor.invisible) or active(actor.stealth) or active(actor.concealment) then return false end
    return true
end
local function actorSummary(g,meta,actor,is_player,detailed)
    local result = {id=M.actorId(meta,actor), name=Details.text(actor.name) or 'unknown',
        x=number(actor.x), y=number(actor.y), life=number(actor.life), max_life=number(actor.max_life),
        faction=Details.text(actor.faction,48) or 'unknown',
        type=Details.text(actor.type,48),subtype=Details.text(actor.subtype,48),
        level=actor.hide_level_tooltip and 'unknown' or number(actor.level),rank=number(actor.rank)}
    -- A stored reaction is a cheap scalar; when present it classifies the actor
    -- without invoking the dynamic reactionToward chain.
    local reaction=number(actor.reaction)
    result.reaction=reaction
    result.hostile=reaction~=nil and reaction<0 or nil
    -- Native grid distance (core.fov.distance), the same metric the native
    -- target range check uses, so a client need not guess Chebyshev vs Euclidean.
    if g.player and finite(g.player.x) and finite(g.player.y) and finite(actor.x) and finite(actor.y) then
        result.distance=number(Distance.grid(g.player.x,g.player.y,actor.x,actor.y))
    end
    if detailed then Details.actor(actor,result) end
    if is_player then Details.player(g,actor,meta,result,detailed) end
    return result
end
local function talentBrief(p,id)
    -- Compact entry for the default snapshot. Full detail (description,
    -- activation, static geometry) lives behind inspect(kind="talent").
    local full=Actions.describe(p,id)
    return {id=full.id,name=Details.text(full.name),mode=Details.text(full.mode,32),
        level=full.level,cooldown=full.cooldown,base_cooldown=full.base_cooldown,
        supported=full.supported,unsupported_reason=full.unsupported_reason,
        sustained_active=full.sustained_active}
end
local function talentSummary(p,id)
    local result=Actions.describe(p,id)
    result.name=Details.text(result.name)
    result.mode=Details.text(result.mode,32)
    result.description=Details.text(result.description,256)
    result.cooldown=number(result.cooldown) or 'unknown'
    return result
end
function M.resolve(g, meta, id)
    if not g.level or not g.player then return nil end
    if id==M.actorId(meta,g.player) then return g.player end
    for _,actor in pairs(g.level.entities or {}) do
        if actor.__is_actor and M.actorId(meta,actor)==id and M.visible(g,actor) then
            local map=g.level.map
            local cell=map.map and map.map[actor.x+actor.y*map.w]
            if cell and cell[map.ACTOR or 3]==actor then return actor end
        end
    end
end
function M.capture(g,meta,radius,options)
    options=options or {}
    local result={session_id=meta.session_id,level_instance_id=meta.level_instance_id,revision=meta.revision,
        phase=meta.phase,control_source=meta.control_source,battle_companion=meta.battle_companion,world_tick=number(g.turn) or 0,
        actor_id_scope='ids embed the native uid and the level instance id; stable within a level, changed by a level change',
        player=Json.null,map=Json.null,ground=Json.null,actors=Json.array(),talents=Json.array(),
        scene={zone_id=g.zone and Details.text(g.zone.short_name),zone_name=g.zone and Details.text(g.zone.name),
            zone_depth=g.level and number(g.level.level),level=g.level and number(g.level.level)}}
    result.dialogs,result.dialogs_truncated=Details.dialogs(g)
    local p,map=g.player,g.level and g.level.map
    if not p or not map or not finite(p.x) or not finite(p.y) then return Details.bounded(result) end
    radius=finite(radius) and math.max(0,math.min(12,math.floor(radius))) or 8
    local detailed=options.detail=='full'
    result.player=actorSummary(g,meta,p,true,detailed)
    result.ground=Items.ground(g,meta,radius)
    result.ground_effects,result.ground_effects_truncated=Details.groundEffects(g,p,radius)
    local talent_ids
    talent_ids,result.talents_truncated=Details.keys(p.talents,64,function(id,level)
        return type(id)=='string' and #id<=256 and finite(level) and level>0
    end)
    for _,id in ipairs(talent_ids) do
        result.talents[#result.talents+1]=detailed and talentSummary(p,id) or talentBrief(p,id)
    end
    for _,actor in pairs(g.level.entities or {}) do
        if actor~=p and actor.__is_actor and M.visible(g,actor) then
            result.actors[#result.actors+1]=actorSummary(g,meta,actor,false)
            table.sort(result.actors,function(a,b) return a.id<b.id end)
            if #result.actors>32 then result.actors[#result.actors]=nil;result.actors_truncated=true end
        end
    end
    if options.include_map==false then return Details.bounded(result) end
    local x0,y0=math.max(0,p.x-radius),math.max(0,p.y-radius)
    local x1,y1=math.min(map.w-1,p.x+radius),math.min(map.h-1,p.y+radius)
    local memory=memories[map] or {};memories[map]=memory
    local rows,cells=Json.array(),Json.array()
    for y=y0,y1 do
        local row={}
        for x=x0,x1 do
            local index=x+y*map.w
            local cell=map.map and map.map[index] or {}
            local actor=cell[map.ACTOR or 3]
            -- In dungeons ESP sets seens without revealing terrain. Require FOV; with an
            -- actor also require static light. This deliberately under-reports
            -- terrain beneath actors seen only by torchlight.
            local visible=M.terrainVisible(g,p,map,x,y)
            local tile={x=x,y=y,visible=visible,known=false}
            if visible then
                local terrain=cell[map.TERRAIN or 1] or {}
                memory[index]=Details.terrain(terrain,p)
            end
            local remembered=memory[index]
            if remembered then
                tile.known=true
                for key,value in pairs(remembered) do tile[key]=value end
            else tile.char='?' end
            if x==p.x and y==p.y then row[#row+1]='@'
            elseif actor and M.visible(g,actor) then row[#row+1]='A'
            else row[#row+1]=tile.char end
            cells[#cells+1]=tile
        end
        rows[#rows+1]=table.concat(row)
    end
    result.map={x=x0,y=y0,width=x1-x0+1,height=y1-y0+1,rows=rows,cells=cells,
        radius=radius,window={x_min=x0,y_min=y0,x_max=x1,y_max=y1},
        legend={['?']='unknown',['@']='player',['A']='perceived actor'},
        memory_scope='terrain observed by this bridge in this session',
        merge_scope='merge this window only within the same session_id and level_instance_id; outside cells are omitted',
        block_scope='terrain only, recorded for player state at last observation; excludes actors, objects, map attributes and movement callbacks'}
    return Details.bounded(result)
end
function M.inspect(g,meta,kind,id,options)
    if kind=='actor' then
        local actor
        if id=='self' or id=='player' then actor=g.player else actor=M.resolve(g,meta,id) end
        if actor then
            local result=actorSummary(g,meta,actor,actor==g.player,true)
            if not options or options.computed~=false then result.computed=ActorCombat.computed(actor) end
            return result
        end
        return nil,'actor_not_visible'
    elseif kind=='character' then
        -- Read-only character panel: the stored fields the native sheet shows,
        -- without evaluating computed getters (see character_scope).
        if not g.player then return nil,'no_player' end
        if id~='player' and id~='self' and id~=M.actorId(meta,g.player) then return nil,'invalid_character_target' end
        local result=actorSummary(g,meta,g.player,true,true)
        result.character_scope='stored fields only; gear/effect computed values (effective accuracy/defense/damage/armor/saves/resists) are not evaluated'
        if not options or options.computed~=false then result.computed=ActorCombat.computed(g.player) end
        return result
    elseif kind=='talent' then
        local def=g.player and g.player.talents_def and g.player.talents_def[id]
        if not def then return nil,'unknown_talent' end
        if g.player.talents and g.player.talents[id] then
            local result=talentSummary(g.player,id)
            local target
            if options and options.target_id~=nil then
                target=M.resolve(g,meta,options.target_id)
                if not target then return nil,'actor_not_visible' end
            end
            local q,reason=Actions.query(g.player,id,target,options and options.x,options and options.y)
            if not q then return nil,reason end
            result.query=q
            -- Advertise the static parts of the query at the top level so a
            -- planner does not have to act before it can see range/cost.
            result.range=q.range;result.radius=q.radius;result.target_shape=q.target_shape
            result.direct_hit=def.direct_hit==true or nil
            result.range_metric='native core.fov.distance (same metric as the native target range check)'
            result.requires_target=q.requires_target;result.current_costs=q.current_costs
            result.base_costs=q.base_costs;result.affordable=q.affordable
            result.cooldown_remaining=q.cooldown_remaining;result.readiness=q.readiness
            -- When a target is supplied, report the native-metric distance and
            -- whether it is inside the talent range, so a client never has to
            -- guess the metric before casting.
            local tx,ty=options and options.x,options and options.y
            if target then tx,ty=target.x,target.y end
            if finite(tx) and finite(ty) and g.player and finite(g.player.x) and finite(g.player.y) then
                local target_distance=Distance.grid(g.player.x,g.player.y,tx,ty)
                result.target_distance=number(target_distance)
                if type(q.range)=='number' then result.in_range=target_distance<=q.range end
            end
            if q.target_shape~=nil or q.radius~=nil or q.range~=nil then
                local scope,residual=Details.damageScope(q.target_shape,def.direct_hit,def.radius)
                result.damage_scope=scope
                result.target_geometry={shape=q.target_shape or 'unknown',radius=q.radius,range=q.range,
                    selffire=Details.selffire({type=q.target_shape,selffire=q.selffire,direct_hit=def.direct_hit}),
                    friendlyfire=Details.friendlyfire({type=q.target_shape,friendlyfire=q.friendlyfire}),
                    piercing=q.target_shape=='beam' or nil,damage_scope=scope,
                    residual_area_radius=residual,
                    source='static talent definition; a dynamic target function can change shape/radius/self-fire at cast time'}
                -- Pre-cast safety: a line/area talent can hit a visible ally or
                -- escort. This is a player-visible read, so the planner can
                -- avoid the cast before it happens.
                if finite(tx) and finite(ty) and g.player then
                    local names,count=Details.friendliesInEffect(g,g.player,tx,ty,q.target_shape,
                        q.radius,q.range,M.visible)
                    if count>0 then
                        result.friendly_fire_risk={count=count,targets=names,
                            note='a visible friendly/neutral unit is inside this talent static damage footprint; casting may quest-fail or kill an ally'}
                    end
                end
            end
            return result
        end
        return nil,'talent_not_learned'
    elseif kind=='progression' then
        if id~='player' or not g.player then return nil,'invalid_progression_target' end
        return Progression.describe(g,g.player)
    elseif kind=='item' then
        return Items.inspect(g,meta,id)
    elseif kind=='compatibility' then
        if id~='runtime' then return nil,'invalid_inspect' end
        return Compat.summary()
    end
    return nil,'unsupported_inspect'
end
function M.listActors(g,meta)
    local out=Json.array()
    if not g.player or not g.level then return out,true end
    for _,actor in pairs(g.level.entities or {}) do
        if actor~=g.player and actor.__is_actor and M.visible(g,actor) then
            out[#out+1]=actorSummary(g,meta,actor,false)
        end
    end
    table.sort(out,function(a,b) return a.id<b.id end)
    return out,true
end
function M.listTalents(g)
    local out=Json.array()
    local p=g.player
    if not p then return out,true end
    local ids,truncated=Details.keys(p.talents,4096,function(id,level)
        return type(id)=='string' and #id<=256 and finite(level) and level>0
    end)
    table.sort(ids)
    for _,id in ipairs(ids) do out[#out+1]=talentSummary(p,id) end
    return out,not truncated
end
return M
