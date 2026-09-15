-- GPL-3.0-or-later. Pure, read-only talent query (spec QRY-01..09).
--
-- This module never runs talent actions, preUseTalent, dynamic info/require
-- functions or unverified getters. Only stored scalars and audited native
-- helpers are read. When an audited input is missing the field is "unknown",
-- and affordability stays a three-state value instead of falling back to the
-- stored base cost (that fallback was the B-03 defect).
local Json = require 'mod.mcp_bridge.Json'
local M = {}
local RESOURCES={'mana','stamina','vim','positive','negative','psi','hate','equilibrium','paradox'}

local function finite(value) return type(value)=='number' and value==value and value>-math.huge and value<math.huge end
-- An audited helper: a real function whose source file matches the declared
-- native path. Overridden functions with the same tag are rejected by the
-- Compatibility audit elsewhere; this only checks the source suffix.
local function native(fn, suffix)
    if type(fn) ~= 'function' then return false end
    local info = debug.getinfo(fn, 'S')
    return info and type(info.source) == 'string' and info.source:sub(1, 1) == '@'
        and info.source:sub(-#suffix) == suffix
end
local function resourceDef(p,name)
    local defs=p.resources_def
    return type(defs)=='table' and defs[name] or nil
end
-- Mirror Actor:postUseTalent's deduction: alterTalentCost, then cost_factor,
-- using only statically declared base costs and the audited native helpers.
local function finalResourceCosts(p,t,base_costs)
    local final,complete={},true
    local ok,suppressed=pcall(function()
        if type(p.attr)~='function' then return false end
        return (p:attr('zero_resource_cost') and true)
            or (p:attr('force_talent_ignore_ressources') and true) or false
    end)
    if not ok then complete=false end
    if t.fake_ressource then suppressed=true end
    if type(p.talent_no_resources)=='table' and p.talent_no_resources[t.id] then suppressed=true end
    local alter=native(p.alterTalentCost,'/mod/class/Actor.lua')
    for name in pairs(base_costs) do
        local base=t[name]
        if suppressed==true then final[name]=0
        elseif type(base)~='number' or not finite(base) then final[name]='unknown';complete=false
        elseif not alter then final[name]='unknown';complete=false
        else
            local called,cost=pcall(p.alterTalentCost,p,t,name,base)
            if not called or not finite(cost) then final[name]='unknown';complete=false
            elseif cost==0 then final[name]=0
            else
                local def=resourceDef(p,name)
                local factor=1
                if def and def.cost_factor~=nil then
                    if type(def.cost_factor)=='function' and native(def.cost_factor,'data/resources.lua') then
                        local factor_ok,value=pcall(def.cost_factor,p,t,false,cost)
                        factor=factor_ok and finite(value) and value or nil
                    elseif type(def.cost_factor)=='number' and finite(def.cost_factor) then factor=def.cost_factor
                    else factor=nil end
                end
                if factor==nil then final[name]='unknown';complete=false
                else final[name]=cost*factor end
            end
        end
    end
    return final,complete
end
-- Per-resource affordability. A normal debit can only be compared when the
-- current cost, the available amount and the resource minimum are all known.
-- No assumption of min=0 and no fallback to the stored base cost.
local function resourceChecks(player,base,costs)
    local checks,any_false,all_true={},false,true
    for name in pairs(base) do
        local amount=costs[name]
        local available=player[name]
        local def=resourceDef(player,name)
        local minimum=def and def.min
        local entry={operation='debit',amount='unknown',available='unknown',minimum='unknown',
            affordable='unknown',reason='cost_dependency_unverified'}
        if finite(amount) then entry.amount=amount end
        if finite(available) then entry.available=available end
        if finite(minimum) then entry.minimum=minimum end
        if not finite(amount) then
            entry.reason='cost_dependency_unverified'
        elseif not finite(available) then
            entry.reason='resource_state_unverified'
        elseif not finite(minimum) then
            entry.reason='resource_minimum_unverified'
        elseif available-amount<minimum then
            entry.affordable=false;entry.reason='insufficient_resource'
        else
            entry.affordable=true;entry.reason='sufficient'
        end
        checks[name]=entry
        if entry.affordable==false then any_false=true end
        if entry.affordable~=true then all_true=false end
    end
    local affordable
    if any_false then affordable=false
    elseif all_true then affordable=true
    else affordable='unknown' end
    return affordable,checks
end
function M.query(player,id,target,x,y)
    local t=player and player.talents_def and player.talents_def[id]
    if type(t)~='table' or t.id~=id then return nil,'invalid_talent' end
    local q={id=id}
    if type(t.range)=='number' and finite(t.range) then q.range=t.range
    elseif type(t.range)=='function' then q.range='unknown'
    else q.range=1 end
    if type(t.requires_target)=='boolean' then q.requires_target=t.requires_target
    elseif type(t.requires_target)=='function' then q.requires_target='unknown'
    else q.requires_target=false end
    if type(t.target)=='string' then q.target_type=t.target
    elseif type(t.target)=='table' then q.target_type='table'
    elseif type(t.target)=='function' then q.target_type='unknown' end
    local cd=player.talents_cd and player.talents_cd[id]
    q.cooldown_remaining=finite(cd) and cd or (cd==nil and 0 or 'unknown')
    local base={}
    for _,key in ipairs(RESOURCES) do
        local value=t[key]
        if finite(value) then base[key]=value
        elseif value~=nil then base[key]='unknown' end
    end
    -- current_costs is the real-time value; base_costs is the stored base.
    local costs,complete=finalResourceCosts(player,t,base)
    q.current_costs=costs;q.costs_complete=complete;q.base_costs=base
    local affordable,checks=resourceChecks(player,base,costs)
    q.affordable=affordable
    q.resource_checks=checks
    local tx,ty=target and target.x or x,target and target.y or y
    if finite(tx) and finite(ty) and finite(player.x) and finite(player.y) then
        q.distance=math.max(math.abs(tx-player.x),math.abs(ty-player.y))
        if type(q.range)=='number' then q.in_range=q.distance<=q.range end
    end
    local learned=player.talents and finite(player.talents[id]) and player.talents[id]>0
    if not learned then q.readiness,q.readiness_reason='blocked','talent_not_learned'
    elseif q.cooldown_remaining=='unknown' then q.readiness,q.readiness_reason='unknown','cooldown_unknown'
    elseif q.cooldown_remaining>0 then q.readiness,q.readiness_reason='blocked','cooldown'
    elseif q.affordable==false then q.readiness,q.readiness_reason='blocked','insufficient_resource'
    elseif q.requires_target==true and not finite(tx) then q.readiness,q.readiness_reason='unknown','target_required'
    else q.readiness,q.readiness_reason='unknown','native_precheck_not_run' end
    q.prefill_supported=true
    q.prefill_modes=Json.array{'actor','position'}
    q.query_is_advisory=true
    return q
end
return M
