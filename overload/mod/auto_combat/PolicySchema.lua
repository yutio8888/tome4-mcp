-- GPL-3.0-or-later. Strict, pure policy schema for tome-auto-combat P1a.
--
-- The policy is data only: no function names, paths, regex or Lua expressions.
-- Unknown keys are rejected. The executor's hard caps can only be tightened by
-- a policy, never relaxed. This module never touches the engine.
local Json=require 'mod.mcp_bridge.Json'
local M={}

M.SCHEMA='tome-auto-combat/v1'
-- P1a baseline (see docs §15.1): the only actions/selectors/predicates/talents
-- a policy may use. Unsupported names are a schema error, not a silent skip.
M.ACTIONS={use_talent=true,attack=true,wait=true}
M.SELECTORS={self=true,nearest_hostile=true,lowest_hp_hostile=true}
M.PREDICATES={always=true,hp_pct=true,resource_pct=true,resource_value=true,
    cooldown_ready=true,talent_known=true,has_effect=true,enemy_count=true,
    nearest_enemy_distance=true,enemy_in_melee=true,enemy_hp_pct=true,computed=true}
M.SAFETY_PREDICATES={hp_pct=true,resource_pct=true,resource_value=true,enemy_in_melee=true}
M.TALENTS={T_CHANT_OF_FORTRESS=true,T_HYMN_OF_SHADOWS=true,T_HEALING_LIGHT=true,
    T_BARRIER=true,T_TWILIGHT=true,T_MOONLIGHT_RAY=true,T_SEARING_LIGHT=true,T_ATTACK=true}
M.SUSTAINS={T_CHANT_OF_FORTRESS=true,T_HYMN_OF_SHADOWS=true}
-- Compile-time hard caps; a policy may only lower these.
M.HARD={max_actions_per_tick=1,max_instant_per_tick=3,max_consecutive_actions=200,
    max_rules=64,max_depth=8,max_candidates=32}

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end
local function integer(n,lo,hi) return finite(n) and n%1==0 and n>=lo and n<=hi end
local function isArray(t) return type(t)=='table' and t~=Json.null end

local function onlyKeys(t,allowed,path,errors)
    for key in pairs(t) do
        if not allowed[key] then errors[#errors+1]={path=path,code='unknown_field',field=tostring(key)} end
    end
end

local function numberField(t,key,lo,hi,path,errors,optional)
    local value=t[key]
    if value==nil and optional then return end
    if not finite(value) or value<lo or value>hi then
        errors[#errors+1]={path=path..'.'..key,code='invalid_number'}
    end
end

local function validateCondition(cond,path,depth,errors)
    if depth>M.HARD.max_depth then errors[#errors+1]={path=path,code='too_deep'};return end
    if type(cond)~='table' then errors[#errors+1]={path=path,code='invalid_condition'};return end
    if cond.all then
        if not isArray(cond.all) then errors[#errors+1]={path=path,code='invalid_all'};return end
        for i,c in ipairs(cond.all) do validateCondition(c,path..'.all['..i..']',depth+1,errors) end
        return
    end
    if cond.any then
        if not isArray(cond.any) then errors[#errors+1]={path=path,code='invalid_any'};return end
        for i,c in ipairs(cond.any) do validateCondition(c,path..'.any['..i..']',depth+1,errors) end
        return
    end
    if cond['not']~=nil then validateCondition(cond['not'],path..'.not',depth+1,errors) return end
    local name,value
    for k,v in pairs(cond) do name,value=k,v;break end
    if name==nil or not M.PREDICATES[name] then
        errors[#errors+1]={path=path,code='unknown_predicate',field=tostring(name)};return
    end
    if name=='always' then return end
    if type(value)~='table' then errors[#errors+1]={path=path,code='invalid_predicate_value'};return end
    if name=='cooldown_ready' or name=='talent_known' then
        if type(value.talent)~='string' or not M.TALENTS[value.talent] then
            errors[#errors+1]={path=path,code='unsupported_talent'}
        end
        return
    end
    if name=='has_effect' then
        if type(value.effect)~='string' then errors[#errors+1]={path=path,code='invalid_effect'} end
        return
    end
    if name=='enemy_in_melee' then return end
    if name=='computed' then
        if type(value.field)~='string' then errors[#errors+1]={path=path,code='invalid_computed_field'} end
        return
    end
    -- numeric comparisons
    local keys=0
    for _,cmp in ipairs{'lt','le','eq','ge','gt'} do
        if value[cmp]~=nil then
            keys=keys+1
            if not finite(value[cmp]) then errors[#errors+1]={path=path,code='invalid_comparison'} end
        end
        if value['cmp_'..cmp]~=nil then errors[#errors+1]={path=path,code='unknown_field',field='cmp_'..cmp} end
    end
    if keys~=1 then errors[#errors+1]={path=path,code='one_comparison_required'} end
    if name=='resource_pct' or name=='resource_value' then
        if type(value.resource)~='string' then errors[#errors+1]={path=path,code='invalid_resource'} end
    end
    onlyKeys(value,{lt=true,le=true,eq=true,ge=true,gt=true,resource=true},path,errors)
end

function M.validate(policy)
    local errors=Json.array()
    if type(policy)~='table' or policy==Json.null then return nil,{{path='',code='not_an_object'}} end
    onlyKeys(policy,{schema=true,id=true,name=true,class=true,updated=true,limits=true,
        sustains=true,safety=true,targeting=true,rules=true,logging=true},'',errors)
    if policy.schema~=M.SCHEMA then errors[#errors+1]={path='schema',code='wrong_schema'} end
    if type(policy.id)~='string' or #policy.id==0 or #policy.id>128 then
        errors[#errors+1]={path='id',code='invalid_id'} end
    if type(policy.name)~='string' or #policy.name>128 then errors[#errors+1]={path='name',code='invalid_name'} end
    if policy.limits~=nil then
        if type(policy.limits)~='table' then errors[#errors+1]={path='limits',code='invalid_limits'}
        else
            onlyKeys(policy.limits,{max_actions_per_tick=true,max_instant_per_tick=true,
                max_consecutive_actions=true,max_rules=true,max_candidates=true},'limits',errors)
            for key,cap in pairs(M.HARD) do
                local value=policy.limits[key]
                if value~=nil and (not integer(value,1,cap)) then
                    errors[#errors+1]={path='limits.'..key,code='limit_cannot_be_relaxed',cap=cap}
                end
            end
        end
    end
    if policy.sustains~=nil then
        if not isArray(policy.sustains) then errors[#errors+1]={path='sustains',code='invalid_sustains'}
        else
            for i,sustain in ipairs(policy.sustains) do
                local path='sustains['..i..']'
                if type(sustain)~='table' then errors[#errors+1]={path=path,code='invalid_sustain'}
                else
                    onlyKeys(sustain,{talent=true,priority=true,min_resource_pct=true},path,errors)
                    if not M.SUSTAINS[sustain.talent] then errors[#errors+1]={path=path,code='unsupported_sustain'} end
                    numberField(sustain,'priority',0,10000,path,errors,true)
                    numberField(sustain,'min_resource_pct',0,100,path,errors,true)
                end
            end
        end
    end
    if policy.safety~=nil then
        if type(policy.safety)~='table' then errors[#errors+1]={path='safety',code='invalid_safety'}
        else
            onlyKeys(policy.safety,{pause_on_new_enemy=true,pause_on_unknown_safety=true,
                flee_below_hp_pct=true,min_hp_pct=true,max_selffire_risk=true},'safety',errors)
            for _,key in ipairs{'pause_on_new_enemy','pause_on_unknown_safety'} do
                if policy.safety[key]~=nil and type(policy.safety[key])~='boolean' then
                    errors[#errors+1]={path='safety.'..key,code='invalid_boolean'}
                end
            end
            numberField(policy.safety,'min_hp_pct',0,100,'safety',errors,true)
            numberField(policy.safety,'flee_below_hp_pct',0,100,'safety',errors,true)
            numberField(policy.safety,'max_selffire_risk',0,100,'safety',errors,true)
            local min,flee=policy.safety.min_hp_pct,policy.safety.flee_below_hp_pct
            if finite(min) and finite(flee) and flee>min then
                errors[#errors+1]={path='safety.flee_below_hp_pct',code='flee_above_min_hp'}
            end
        end
    end
    if policy.targeting~=nil then
        if type(policy.targeting)~='table' then errors[#errors+1]={path='targeting',code='invalid_targeting'}
        else
            onlyKeys(policy.targeting,{default=true,tie_break=true},'targeting',errors)
            if policy.targeting.default~=nil and not M.SELECTORS[policy.targeting.default] then
                errors[#errors+1]={path='targeting.default',code='unsupported_selector'}
            end
        end
    end
    if not isArray(policy.rules) or #policy.rules==0 then
        errors[#errors+1]={path='rules',code='rules_required'}
    else
        local cap=policy.limits and policy.limits.max_rules or M.HARD.max_rules
        if #policy.rules>cap then errors[#errors+1]={path='rules',code='too_many_rules'} end
        local ids={}
        for i,rule in ipairs(policy.rules) do
            local path='rules['..i..']'
            if type(rule)~='table' then errors[#errors+1]={path=path,code='invalid_rule'}
            else
                onlyKeys(rule,{id=true,priority=true,when=true,['then']=true,emergency=true,enabled=true},path,errors)
                if type(rule.id)~='string' or #rule.id==0 or #rule.id>64 or ids[rule.id] then
                    errors[#errors+1]={path=path..'.id',code='invalid_or_duplicate_id'}
                else ids[rule.id]=true end
                numberField(rule,'priority',0,10000,path,errors)
                if rule.emergency~=nil and type(rule.emergency)~='boolean' then
                    errors[#errors+1]={path=path..'.emergency',code='invalid_boolean'}
                end
                if rule.enabled~=nil and type(rule.enabled)~='boolean' then
                    errors[#errors+1]={path=path..'.enabled',code='invalid_boolean'}
                end
                validateCondition(rule.when,path..'.when',0,errors)
                if type(rule['then'])~='table' then
                    errors[#errors+1]={path=path..'.then',code='invalid_then'}
                else
                    onlyKeys(rule['then'],{action=true,talent=true,target=true},path..'[then]',errors)
                    if not M.ACTIONS[rule['then'].action] then
                        errors[#errors+1]={path=path..'.then.action',code='unsupported_action'}
                    end
                    if rule['then'].action=='use_talent' and not M.TALENTS[rule['then'].talent] then
                        errors[#errors+1]={path=path..'.then.talent',code='unsupported_talent'}
                    end
                    if rule['then'].target~=nil and not M.SELECTORS[rule['then'].target] then
                        errors[#errors+1]={path=path..'.then.target',code='unsupported_selector'}
                    end
                end
            end
        end
    end
    if #errors>0 then return nil,errors end
    return true
end

-- Deterministic canonical encoding: arrays keep order, object keys are sorted.
local function canonical(value)
    if type(value)~='table' then
        if type(value)=='string' then return Json.encode(value) end
        return tostring(value)
    end
    if #value>0 then
        local parts={}
        for i=1,#value do parts[#parts+1]=canonical(value[i]) end
        return '['..table.concat(parts,',')..']'
    end
    local keys={}
    for key in pairs(value) do keys[#keys+1]=key end
    table.sort(keys)
    local parts={}
    for _,key in ipairs(keys) do parts[#parts+1]=Json.encode(key)..':'..canonical(value[key]) end
    return '{'..table.concat(parts,',')..'}'
end

-- `updated` is editable metadata and must not change the content hash.
function M.canonical(policy)
    local copy={}
    for key,value in pairs(policy) do if key~='updated' then copy[key]=value end end
    return canonical(copy)
end

function M.hash(policy)
    local data=M.canonical(policy)
    local ok,md5=pcall(require,'md5')
    if ok and type(md5)=='table' and md5.sumhexa then return md5.sumhexa(data) end
    -- Deterministic FNV-1a fallback for environments without the md5 module.
    local hash=2166136261
    for i=1,#data do
        hash=bit.bxor(hash,data:byte(i))
        hash=bit.band(hash*16777619,0xffffffff)
    end
    return string.format('%08x',hash)
end
return M
