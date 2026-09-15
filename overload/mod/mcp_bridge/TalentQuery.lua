-- GPL-3.0-or-later. Pure, read-only talent query (spec QRY-01..09).
--
-- This module never runs talent actions, preUseTalent, dynamic info/require
-- functions or unverified getters. Only stored scalars and registered native
-- dependencies are read. When an audited input is missing the field is
-- "unknown", and affordability stays a three-state value instead of falling
-- back to the stored base cost (that fallback was the B-03 defect).
local Json = require 'mod.mcp_bridge.Json'
local Compat = require 'mod.mcp_bridge.NativeCompatibility'
local Distance = require 'mod.mcp_bridge.Distance'
local M = {}
local RESOURCES={'mana','stamina','vim','positive','negative','psi','hate','equilibrium','paradox'}

local function finite(value) return type(value)=='number' and value==value and value>-math.huge and value<math.huge end
local function resourceDef(p,name)
    local defs=p.resources_def
    return type(defs)=='table' and defs[name] or nil
end
-- A read-only dependency is only called after it has been registered once.
-- Re-registering an existing id never overwrites the baseline, so a later
-- replacement stays failed instead of being adopted.
local function registerOnce(id,domain,fn,path,purpose)
    if Compat.hasDependency and Compat.hasDependency(id) then return end
    Compat.registerDependency(id,domain,fn,path,purpose)
end
function M.registerNative(player)
    if type(player)~='table' then return end
    if type(player.attr)=='function' then
        registerOnce('actor.attr','talent_query',player.attr,'/engine/Entity.lua','resource suppression flags')
    end
    if type(player.alterTalentCost)=='function' then
        registerOnce('actor.alterTalentCost','talent_query',player.alterTalentCost,'/mod/class/Actor.lua','talent cost mutation')
    end
    local defs=player.resources_def
    if type(defs)=='table' then
        for name,def in pairs(defs) do
            if type(def)=='table' and type(def.cost_factor)=='function' then
                registerOnce('resource.cost_factor:'..name,'talent_query',def.cost_factor,'data/resources.lua','resource cost factor')
            end
        end
    end
end
-- Mirror Actor:postUseTalent's deduction: alterTalentCost, then cost_factor,
-- using only stored base costs and registered native dependencies. Returns
-- per-resource reasons so the caller can explain an unknown value.
local function finalResourceCosts(p,t,base_costs)
    local final,complete,reasons={},true,{}
    local suppressed=false
    local attr_fn=p.attr
    if type(attr_fn)=='function' then
        local attr,attr_reason=Compat.dependency('actor.attr',attr_fn)
        if not attr then
            -- Suppression flags cannot be trusted: report every cost unknown
            -- rather than assume no suppression (which could yield a false
            -- affordable=true). The replacement function is never called.
            for name in pairs(base_costs) do
                final[name]='unknown';reasons[name]=attr_reason or 'suppression_unverified'
            end
            return final,false,reasons
        end
        local ok,value=pcall(function()
            return (attr(p,'zero_resource_cost') and true) or (attr(p,'force_talent_ignore_ressources') and true) or false
        end)
        if ok and value==true then suppressed=true end
    end
    if t.fake_ressource then suppressed=true end
    if type(p.talent_no_resources)=='table' and p.talent_no_resources[t.id] then suppressed=true end
    local alter=Compat.dependency('actor.alterTalentCost',p.alterTalentCost)
    for name in pairs(base_costs) do
        local base=t[name]
        if suppressed==true then final[name]=0
        elseif type(base)~='number' or not finite(base) then
            final[name]='unknown';complete=false;reasons[name]='cost_dependency_unverified'
        elseif not alter then
            final[name]='unknown';complete=false;reasons[name]='cost_helper_unverified'
        else
            local called,cost=pcall(alter,p,t,name,base)
            if not called or not finite(cost) then
                final[name]='unknown';complete=false;reasons[name]='cost_helper_unverified'
            elseif cost==0 then final[name]=0
            else
                local def=resourceDef(p,name)
                local factor=1
                if def and def.cost_factor~=nil then
                    if type(def.cost_factor)=='function' then
                        local cf,cfreason=Compat.dependency('resource.cost_factor:'..name,def.cost_factor)
                        if not cf then
                            factor=nil;reasons[name]=cfreason or 'cost_factor_unverified'
                        else
                            local factor_ok,value=pcall(cf,p,t,false,cost)
                            factor=factor_ok and finite(value) and value or nil
                            if factor==nil then reasons[name]='cost_factor_unverified' end
                        end
                    elseif type(def.cost_factor)=='number' and finite(def.cost_factor) then factor=def.cost_factor
                    else factor=nil;reasons[name]='cost_factor_unverified' end
                end
                if factor==nil then final[name]='unknown';complete=false
                else final[name]=cost*factor end
            end
        end
    end
    return final,complete,reasons
end
-- Per-resource affordability. A normal debit can only be compared when the
-- current cost, the available amount and the resource minimum are all known.
-- No assumption of min=0 and no fallback to the stored base cost.
local function resourceChecks(player,base,costs,reasons)
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
            entry.reason=reasons[name] or 'cost_dependency_unverified'
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
    M.registerNative(player)
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
    local costs,complete,reasons=finalResourceCosts(player,t,base)
    q.current_costs=costs;q.costs_complete=complete;q.base_costs=base
    local affordable,checks=resourceChecks(player,base,costs,reasons)
    q.affordable=affordable
    q.resource_checks=checks
    local tx,ty=target and target.x or x,target and target.y or y
    if finite(tx) and finite(ty) and finite(player.x) and finite(player.y) then
        q.distance=Distance.grid(player.x,player.y,tx,ty)
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
