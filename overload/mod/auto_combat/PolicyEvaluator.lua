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
        local has=ctx.has_effect and ctx.has_effect(value.effect,value.who or 'self')
        return has==nil and UNKNOWN or (has and TRUE or FALSE)
    end
    if name=='ally_count' then
        local op,rhs=comparison(value); return compare(ctx.ally_count,op,rhs)
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
    if name=='enemy_rank' then
        local op,rhs=comparison(value); return compare(ctx.enemy_rank,op,rhs)
    end
    if name=='enemy_level' then
        local op,rhs=comparison(value); return compare(ctx.enemy_level,op,rhs)
    end
    if name=='enemy_distance' then
        local op,rhs=comparison(value); return compare(ctx.enemy_distance,op,rhs)
    end
    if name=='enemy_type' then
        if ctx.enemy_type==nil then return UNKNOWN end
        return ctx.enemy_type==value.eq and TRUE or FALSE
    end
    -- ToME rank bands: normal 2, elite 3/3.2, unique/boss >=3.5, boss 4+.
    if name=='enemy_is_elite' then
        if ctx.enemy_rank==nil then return UNKNOWN end
        return ctx.enemy_rank>=3 and TRUE or FALSE
    end
    if name=='enemy_is_boss' then
        if ctx.enemy_rank==nil then return UNKNOWN end
        return ctx.enemy_rank>=4 and TRUE or FALSE
    end
    if name=='computed' then
        -- Numeric comparison over the audited panel getters (design §5.2/§5.6).
        local op,rhs=comparison(value)
        local have=ctx.computed and ctx.computed(value.field)
        return compare(have,op,rhs)
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

-- v1.6 scheduling mode resolution. This is pure data: the plugin applies the
-- policy's chosen mode instead of a built-in tactical layer. Missing mode keeps
-- the conservative legacy behaviour (`stop` on no enemy, `emergency_only`
-- below the HP threshold, `pause` on a new enemy) so an un-migrated policy is
-- never silently widened.
--
-- D-3: `on_new_enemy` is an ordinary preset/mode choice. `continue` keeps the
-- visible target set current without parking the run; `pause` is the legacy
-- conservative default. The legacy boolean `safety.pause_on_new_enemy=false`
-- still maps to `continue` so an older policy keeps its authored meaning.
function M.newEnemyMode(policy)
    local mode=policy.mode or {}
    local safety=policy.safety or {}
    local value=mode.on_new_enemy
    if value==nil then
        value=safety.pause_on_new_enemy==false and 'continue' or 'pause'
    end
    return value
end

function M.scheduling(policy,hp_pct)
    local mode=policy.mode or {}
    local safety=policy.safety or {}
    local minHp=safety.min_hp_pct
    local flee=safety.flee_below_hp_pct
    local onLowHp=mode.on_low_hp or 'emergency_only'
    local onNoEnemy=mode.on_no_enemy or 'stop'
    local onNewEnemy=M.newEnemyMode(policy)
    local belowFlee=type(hp_pct)=='number' and flee~=nil and hp_pct<flee
    local lowHp=type(hp_pct)=='number' and minHp~=nil and hp_pct<minHp
    local layer='normal'
    local pauseReason=nil
    if lowHp and onLowHp=='pause' then
        layer='pause'
        pauseReason=belowFlee and 'flee_below_hp_pct' or 'below_min_hp_pct'
    elseif lowHp and onLowHp=='emergency_only' then
        layer='emergency'
    end
    return {on_low_hp=onLowHp,on_no_enemy=onNoEnemy,on_new_enemy=onNewEnemy,low_hp=lowHp,
        below_flee=belowFlee,layer=layer,pause_reason=pauseReason}
end

-- Returns one of (every decision carries `results`, the §10 per-rule trace):
--   {decision='act',rule,action,talent,target,critical,emergency,results}
--   {decision='pause',reason,critical,rule,results}
--   {decision='hold',reason,results}
-- `results` is an ordered array of {rule, result='true'|'false'|'unknown'|'denied',
-- emergency=bool} for the rules considered in this layer, bounded by the rule cap.
-- MFT-REV-03 (Option A): the ordered target plan may declare the actor binding
-- even when `then.target` and `targeting.default` are both absent. The first
-- actor step selector is the source of truth for the action binding in that
-- case, so it is resolved by the snapshot and honoured by the planner.
local function actorStepSelector(then_)
    local plan=then_ and then_.target_plan
    if type(plan)~='table' then return nil end
    for _,step in ipairs(plan) do
        if step.request=='actor' and step.selector~=nil then return step.selector end
    end
    return nil
end
M.actorStepSelector=actorStepSelector

function M.evaluate(policy,ctx,opts)
    ctx=ctx or {}
    opts=opts or {}
    local limits=policy.limits or {}
    local maxActions=limits.max_actions_per_tick or 1
    local attempts=ctx.attempts or 0
    local safety=policy.safety or {}
    local sched=M.scheduling(policy,ctx.hp_pct)
    local critical=sched.low_hp
    if sched.layer=='pause' then
        return {decision='pause',reason=sched.pause_reason,critical=true,layer='pause',results={}}
    end
    -- Target-related conditions must be evaluated against the same selector the
    -- action will bind (§5.3). `opts.context_for(selector)` lets the caller (the
    -- controller / dry run) supply a per-selector context; without it the single
    -- `ctx` is used, preserving the P1 behaviour for unit tests.
    local default_selector=policy.targeting and policy.targeting.default
    local context_for=opts.context_for
    local selector_cache={}
    local function ctx_for(rule)
        if not context_for then return ctx end
        local selector=rule['then'].target or default_selector
        if selector==nil then selector=actorStepSelector(rule['then']) end
        if selector==nil then return ctx end
        local cached=selector_cache[selector]
        if cached==nil then
            cached=context_for(selector) or ctx
            cached.attempts=ctx.attempts
            cached.denied=ctx.denied
            selector_cache[selector]=cached
        end
        return cached
    end
    local eligible={}
    for _,rule in ipairs(policy.rules or {}) do
        local emergency=rule.emergency==true
        local include
        if sched.layer=='emergency' then include=emergency
        else include=true end
        if rule.enabled~=false and include then eligible[#eligible+1]=rule end
    end
    table.sort(eligible,function(a,b)
        if a.priority~=b.priority then return a.priority>b.priority end
        return a.id<b.id
    end)
    local results={}
    local layer=sched.layer
    -- Budget exhaustion never falls through to a different layer: in emergency
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
            local rule_ctx=ctx_for(rule)
            local value=M.evalCondition(rule.when,rule_ctx)
            results[#results+1]={rule=rule.id,result=value,emergency=rule.emergency==true}
            if value==TRUE then
                local target=rule['then'].target or (policy.targeting and policy.targeting.default)
                if target==nil then target=actorStepSelector(rule['then']) end
                return {decision='act',rule=rule.id,action=rule['then'].action,talent=rule['then'].talent,
                    max_turns=rule['then'].max_turns,
                    direction=rule['then'].direction,
                    destination=rule['then'].destination,target_plan=rule['then'].target_plan,
                    target=target,critical=critical,emergency=rule.emergency==true,results=results,layer=layer}
            elseif value==UNKNOWN and isSafety(rule.when) then
                unknownRule=unknownRule or rule
            end
        end
    end
    if sched.layer=='emergency' then
        -- D-1 (P1, round anor-reg-01): an emergency rule that matched in this
        -- opportunity but was refused (denied) must not park the run. A pause
        -- here freezes the world (the player still holds full energy), so a
        -- native cooldown would never decay and every restart would repeat the
        -- same deny -> pause forever. Continue the same opportunity over the
        -- remaining normal rules: falling through is ordinary policy
        -- evaluation, not a plugin-level strategy restriction. Only when
        -- nothing at all is applicable is the typed reason the refusal
        -- (`action_denied`), never `no_emergency_action`.
        local refusedRule
        for _,row in ipairs(results) do
            if row.emergency and row.result=='denied' then
                refusedRule=refusedRule or row.rule
            end
        end
        if refusedRule then
            local fallback={}
            for _,rule in ipairs(policy.rules or {}) do
                if rule.enabled~=false and rule.emergency~=true then fallback[#fallback+1]=rule end
            end
            table.sort(fallback,function(a,b)
                if a.priority~=b.priority then return a.priority>b.priority end
                return a.id<b.id
            end)
            for _,rule in ipairs(fallback) do
                if ctx.denied and ctx.denied[rule.id] then
                    results[#results+1]={rule=rule.id,result='denied',emergency=false,fallback=true}
                else
                    local rule_ctx=ctx_for(rule)
                    local value=M.evalCondition(rule.when,rule_ctx)
                    results[#results+1]={rule=rule.id,result=value,emergency=false,fallback=true}
                    if value==TRUE then
                        local target=rule['then'].target or default_selector
                        if target==nil then target=actorStepSelector(rule['then']) end
                        return {decision='act',rule=rule.id,action=rule['then'].action,
                            talent=rule['then'].talent,max_turns=rule['then'].max_turns,
                            direction=rule['then'].direction,destination=rule['then'].destination,
                            target_plan=rule['then'].target_plan,target=target,critical=true,
                            emergency=false,fallback=true,results=results,layer=layer}
                    end
                end
            end
            return {decision='pause',reason='action_denied',critical=true,rule=refusedRule,
                results=results,layer=layer,fallback=true}
        end
        return {decision='pause',reason=sched.below_flee and 'flee_below_hp_pct' or 'no_emergency_action',
            critical=true,rule=unknownRule and unknownRule.id,results=results,layer=layer}
    end
    if unknownRule and safety.pause_on_unknown_safety~=false then
        return {decision='pause',reason='unknown_safety',rule=unknownRule.id,results=results,layer=layer}
    end
    return {decision='hold',reason='no_rule_matched',results=results,layer=layer}
end
return M
