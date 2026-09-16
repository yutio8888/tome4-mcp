-- GPL-3.0-or-later. Pure, three-valued policy evaluator for tome-auto-combat P1a.
--
-- The evaluator is side-effect free: it never touches the engine, never rolls
-- RNG, and returns a decision the controller then executes/arbitrates. All
-- state is injected through `ctx`, so the same code runs in unit tests and in
-- the live executor.
--
-- ctx contract (all optional; missing -> unknown):
--   hp_pct, resource_pct(name), resource_value(name), cooldown_ready(talent),
--   talent_known(talent), has_effect(effect,who), enemy_count,
--   nearest_enemy_distance, enemy_in_melee, enemy_hp_pct, computed(field),
--   attempts (real call attempts already spent in this action opportunity).
local Schema=require 'mod.auto_combat.PolicySchema'
local M={}
local TRUE,FALSE,UNKNOWN='true','false','unknown'
M.TRUE,M.FALSE,M.UNKNOWN=TRUE,FALSE,UNKNOWN

local function tri_not(v) if v==UNKNOWN then return UNKNOWN end return v==TRUE and FALSE or TRUE end
local function tri_and(a,b)
    if a==FALSE or b==FALSE then return FALSE end
    if a==UNKNOWN or b==UNKNOWN then return UNKNOWN end
    return TRUE
end
local function tri_or(a,b)
    if a==TRUE or b==TRUE then return TRUE end
    if a==UNKNOWN or b==UNKNOWN then return UNKNOWN end
    return FALSE
end

local function compare(a,op,b)
    if a==nil or b==nil then return UNKNOWN end
    if op=='lt' then return a<b and TRUE or FALSE end
    if op=='le' then return a<=b and TRUE or FALSE end
    if op=='eq' then return a==b and TRUE or FALSE end
    if op=='ge' then return a>=b and TRUE or FALSE end
    if op=='gt' then return a>b and TRUE or FALSE end
    return UNKNOWN
end

local function comparison(value)
    for _,op in ipairs{'lt','le','eq','ge','gt'} do
        if value[op]~=nil then return op,value[op] end
    end
    return nil,nil
end

function M.evalCondition(cond,ctx)
    if type(cond)~='table' then return UNKNOWN end
    if cond.all then
        local result=TRUE
        for _,child in ipairs(cond.all) do result=tri_and(result,M.evalCondition(child,ctx)) end
        return result
    end
    if cond.any then
        local result=FALSE
        for _,child in ipairs(cond.any) do result=tri_or(result,M.evalCondition(child,ctx)) end
        return result
    end
    if cond['not']~=nil then return tri_not(M.evalCondition(cond['not'],ctx)) end
    local name,value=next(cond)
    if name=='always' then return TRUE end
    if name=='hp_pct' then
        local op,rhs=comparison(value); return compare(ctx.hp_pct,op,rhs)
    end
    if name=='resource_pct' then
        local op,rhs=comparison(value)
        local have=ctx.resource_pct and ctx.resource_pct(value.resource)
        return compare(have,op,rhs)
    end
    if name=='resource_value' then
        local op,rhs=comparison(value)
        local have=ctx.resource_value and ctx.resource_value(value.resource)
        return compare(have,op,rhs)
    end
    if name=='cooldown_ready' then
        local ready=ctx.cooldown_ready and ctx.cooldown_ready(value.talent)
        return ready==nil and UNKNOWN or (ready and TRUE or FALSE)
    end
    if name=='talent_known' then
        local known=ctx.talent_known and ctx.talent_known(value.talent)
        return known==nil and UNKNOWN or (known and TRUE or FALSE)
    end
    if name=='has_effect' then
        local has=ctx.has_effect and ctx.has_effect(value.effect,value.who)
        return has==nil and UNKNOWN or (has and TRUE or FALSE)
    end
    if name=='enemy_count' then
        local op,rhs=comparison(value); return compare(ctx.enemy_count,op,rhs)
    end
    if name=='nearest_enemy_distance' then
        local op,rhs=comparison(value); return compare(ctx.nearest_enemy_distance,op,rhs)
    end
    if name=='enemy_in_melee' then
        return ctx.enemy_in_melee==nil and UNKNOWN or (ctx.enemy_in_melee and TRUE or FALSE)
    end
    if name=='enemy_hp_pct' then
        local op,rhs=comparison(value); return compare(ctx.enemy_hp_pct,op,rhs)
    end
    if name=='computed' then
        local computed=ctx.computed and ctx.computed(value.field)
        return computed==nil and UNKNOWN or (computed and TRUE or FALSE)
    end
    return UNKNOWN
end

local function isSafety(cond)
    if type(cond)~='table' then return false end
    if cond.all then
        for _,c in ipairs(cond.all) do if isSafety(c) then return true end end
        return false
    end
    if cond.any then
        for _,c in ipairs(cond.any) do if isSafety(c) then return true end end
        return false
    end
    if cond['not']~=nil then return isSafety(cond['not']) end
    for name in pairs(cond) do if Schema.SAFETY_PREDICATES[name] then return true end end
    return false
end
M.isSafety=isSafety

function M.critical(policy,hp_pct)
    local minHp=policy.safety and policy.safety.min_hp_pct
    if minHp==nil or type(hp_pct)~='number' then return false end
    return hp_pct<minHp
end

-- Returns one of (every decision carries `results`, the §10 per-rule trace):
--   {decision='act',rule,action,talent,target,critical,emergency,results}
--   {decision='pause',reason,critical,rule,results}
--   {decision='hold',reason,results}
-- `results` is an ordered array of {rule, result='true'|'false'|'unknown'|'denied',
-- emergency=bool} for the rules considered in this layer, bounded by the rule cap.
function M.evaluate(policy,ctx)
    ctx=ctx or {}
    local limits=policy.limits or {}
    local maxActions=limits.max_actions_per_tick or 1
    local attempts=ctx.attempts or 0
    local safety=policy.safety or {}
    local critical=M.critical(policy,ctx.hp_pct)
    local eligible={}
    for _,rule in ipairs(policy.rules or {}) do
        local emergency=rule.emergency==true
        if rule.enabled~=false and ((critical and emergency) or (not critical and not emergency)) then
            eligible[#eligible+1]=rule
        end
    end
    table.sort(eligible,function(a,b)
        if a.priority~=b.priority then return a.priority>b.priority end
        return a.id<b.id
    end)
    local results={}
    local layer=critical and 'emergency' or 'normal'
    -- Budget exhaustion never falls through to a different layer: in critical
    -- state it must not become a reason to fire normal output.
    if attempts>=maxActions then
        for _,rule in ipairs(eligible) do
            results[#results+1]={rule=rule.id,result='skipped',emergency=rule.emergency==true}
        end
        return {decision='pause',reason='budget_exhausted',critical=critical,results=results,layer=layer}
    end
    local unknownRule
    for _,rule in ipairs(eligible) do
        -- A rule denied earlier in the same action opportunity is skipped, not
        -- retried as-is (and not mistaken for an unknown safety condition).
        if ctx.denied and ctx.denied[rule.id] then
            results[#results+1]={rule=rule.id,result='denied',emergency=rule.emergency==true}
        else
            local value=M.evalCondition(rule.when,ctx)
            results[#results+1]={rule=rule.id,result=value,emergency=rule.emergency==true}
            if value==TRUE then
                local target=rule['then'].target or (policy.targeting and policy.targeting.default)
                return {decision='act',rule=rule.id,action=rule['then'].action,talent=rule['then'].talent,
                    target=target,critical=critical,emergency=rule.emergency==true,results=results,layer=layer}
            elseif value==UNKNOWN and isSafety(rule.when) then
                unknownRule=unknownRule or rule
            end
        end
    end
    if critical then
        return {decision='pause',reason='no_emergency_action',critical=true,
            rule=unknownRule and unknownRule.id,results=results,layer=layer}
    end
    if unknownRule and safety.pause_on_unknown_safety~=false then
        return {decision='pause',reason='unknown_safety',rule=unknownRule.id,results=results,layer=layer}
    end
    return {decision='hold',reason='no_rule_matched',results=results,layer=layer}
end
return M
