-- GPL-3.0-or-later. Build the evaluator context from bounded, audited reads.
--
-- The snapshot is the single place where "what the plugin sees" is assembled,
-- so a rule condition and the action it selects operate on the same bound
-- target. It performs no dynamic getters, no RNG and no talent callbacks; every
-- read is injected through `host`, which the live adapter implements with the
-- bridge's existing audited readers.
local Distance=require 'mod.mcp_bridge.Distance'
local M={}

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end

-- Deterministic candidate ordering: distance, then y, then x, then id.
local function byDistance(origin)
    return function(a,b)
        local da=Distance.grid(origin.x,origin.y,a.x,a.y)
        local db=Distance.grid(origin.x,origin.y,b.x,b.y)
        if da~=db then return da<db end
        if a.y~=b.y then return a.y<b.y end
        if a.x~=b.x then return a.x<b.x end
        return tostring(a.id)<tostring(b.id)
    end
end

-- Choose the bound target for a selector. Returns the hostile entry, never a
-- stale reference: the caller uses the same entry for conditions and execution.
function M.select(selector,hostiles,origin)
    if type(hostiles)~='table' or #hostiles==0 or not origin then return nil end
    local sorted={}
    for _,entry in ipairs(hostiles) do sorted[#sorted+1]=entry end
    table.sort(sorted,byDistance(origin))
    if selector=='lowest_hp_hostile' then
        local best
        for _,entry in ipairs(sorted) do
            if finite(entry.hp_pct) and (best==nil or entry.hp_pct<best.hp_pct) then best=entry end
        end
        return best or sorted[1]
    end
    if selector=='self' then return nil end
    return sorted[1]  -- default: nearest_hostile
end

function M.nearestDistance(origin,hostiles)
    local best
    for _,entry in ipairs(hostiles or {}) do
        if finite(entry.x) and finite(entry.y) then
            local d=Distance.grid(origin.x,origin.y,entry.x,entry.y)
            if best==nil or d<best then best=d end
        end
    end
    return best
end

-- host contract:
--   host.origin() -> {x,y}
--   host.hp_pct() -> number|nil
--   host.resource_pct(name), host.resource_value(name)
--   host.talent_known(id), host.cooldown_ready(id), host.has_effect(effect)
--   host.hostiles() -> array of {id,x,y,hp_pct}
--   host.computed(field)
function M.build(host,policy,selector)
    local ctx={}
    local origin=host.origin and host.origin() or nil
    ctx.hp_pct=host.hp_pct and host.hp_pct() or nil
    ctx.resource_pct=host.resource_pct
    ctx.resource_value=host.resource_value
    ctx.talent_known=host.talent_known
    ctx.cooldown_ready=host.cooldown_ready
    ctx.has_effect=host.has_effect
    ctx.computed=host.computed
    local hostiles_read=type(host.hostiles)=='function'
    local hostiles=hostiles_read and host.hostiles() or {}
    ctx.hostile_count=#hostiles
    ctx.enemy_count=#hostiles
    if origin then
        local nearest=hostiles_read and M.nearestDistance(origin,hostiles) or nil
        ctx.nearest_enemy_distance=nearest
        -- A real hostile read makes melee knowable: an empty set is definitely
        -- not in melee. A missing read stays unknown.
        if hostiles_read then ctx.enemy_in_melee=(nearest~=nil and nearest<=1) end
    end
    selector=selector or (policy.targeting and policy.targeting.default)
    ctx.binding_selector=selector
    local bound=M.select(selector,hostiles,origin)
    if bound then
        ctx.bound_target=bound.id
        ctx.enemy_hp_pct=bound.hp_pct
        ctx.enemy_distance=origin and finite(bound.x) and Distance.grid(origin.x,origin.y,bound.x,bound.y) or nil
    end
    return ctx
end
return M
