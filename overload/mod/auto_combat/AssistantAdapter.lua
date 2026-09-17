-- GPL-3.0-or-later. Generation-only adapter for the legacy auto-talent
-- assistant (`tome-auto_talent_assistant`, addon version 2.3.9 on ToME 1.7.4).
--
-- This module is PURE: no engine access, no assistant calls, no runtime
-- coupling and no RNG. It translates a *pinned, normalized assistant export*
-- into an auto-combat policy **draft** (data only). It never approves,
-- activates or starts a run; a human confirms the draft.
--
-- Why a normalized export and not the assistant's `.tata`/`actor.Assistant`
-- tables: the assistant's condition DSL is an assistant-internal, version-
-- specific structure (numeric `conditionType`, pointer-rebuilt `.tata` files)
-- with no stable ABI. Guessing it would violate the design's "fixed version +
-- explicit field mapping, never guess unsupported fields" rule. The export
-- below is the explicit, documented subset; anything else is refused or
-- reported, never silently dropped.
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local M={}

M.FORMAT='tome-auto-combat-assistant-export/v1'
M.PINNED={addon='auto_talent_assistant',addon_version='2.3.9',tome_version='1.7.4'}
-- Top-level and per-entry keys the adapter understands. Unknown keys are
-- reported as unsupported.
M.CONFIG_KEYS={format=true,assistant=true,class=true,id=true,name=true,
    settings=true,sustains=true,talents=true,unsupported_fields=true,notes=true}
M.SETTINGS_KEYS={max_actions_per_tick=true,min_hp_pct=true,flee_below_hp_pct=true,
    pause_on_new_enemy=true,pause_on_unknown_safety=true,max_selffire_risk=true,
    default_target=true}
M.TALENT_KEYS={id=true,talent=true,enabled=true,priority=true,emergency=true,
    action=true,when=true,target=true,min_resource_pct=true}
M.SUSTAIN_KEYS={talent=true,enabled=true,priority=true,min_resource_pct=true}

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end
local function isArray(t) return type(t)=='table' and #t>0 end

function M.versionKey(v)
    if type(v)~='table' then return tostring(v) end
    local parts={}
    for i=1,#v do parts[#parts+1]=tostring(v[i]) end
    return table.concat(parts,'.')
end

-- Pin check. Returns the detected version descriptor or `nil, error`.
function M.detect(config)
    if type(config)~='table' then return nil,{code='not_a_table'} end
    local assistant=config.assistant
    if type(assistant)~='table' then return nil,{code='missing_assistant'} end
    if assistant.addon~=M.PINNED.addon then
        return nil,{code='unknown_addon',expected=M.PINNED.addon,got=assistant.addon}
    end
    local got=M.versionKey(assistant.addon_version)
    if got~=M.PINNED.addon_version then
        return nil,{code='assistant_version_mismatch',expected=M.PINNED.addon_version,got=got}
    end
    if config.format~=M.FORMAT then
        return nil,{code='unsupported_format',expected=M.FORMAT,got=config.format}
    end
    return {version=got,addon=assistant.addon,addon_version=got,
        tome_version=M.versionKey(assistant.tome_version),format=config.format}
end

local function reportUnsupported(out,path,code,detail)
    local entry={path=path,code=code}
    if detail then for k,v in pairs(detail) do entry[k]=v end end
    out[#out+1]=entry
    return entry
end

local function reportWarning(out,path,code,detail)
    local entry={path=path,code=code}
    if detail then for k,v in pairs(detail) do entry[k]=v end end
    out[#out+1]=entry
    return entry
end

-- Recursively translate a policy-shaped condition tree. Returns the condition,
-- or `nil` when any leaf is unsupported (the whole rule is then dropped rather
-- than silently weakening the condition).
local function translateCondition(cond,path,warnings,unsupported,depth)
    depth=depth or 0
    if depth>Schema.HARD.max_depth then
        reportUnsupported(unsupported,path,'condition_too_deep')
        return nil
    end
    if type(cond)~='table' then
        reportUnsupported(unsupported,path,'invalid_condition')
        return nil
    end
    if cond.all~=nil or cond.any~=nil then
        local key=cond.all~=nil and 'all' or 'any'
        local list=cond[key]
        if type(list)~='table' then
            reportUnsupported(unsupported,path,'invalid_'..key)
            return nil
        end
        local out={}
        for index,child in ipairs(list) do
            local translated=translateCondition(child,path..'.'..key..'['..index..']',warnings,unsupported,depth+1)
            if translated==nil then return nil end
            out[#out+1]=translated
        end
        return {[key]=out}
    end
    if cond['not']~=nil then
        local translated=translateCondition(cond['not'],path..'.not',warnings,unsupported,depth+1)
        if translated==nil then return nil end
        return {['not']=translated}
    end
    local name,value=next(cond)
    if name==nil then
        reportUnsupported(unsupported,path,'empty_condition')
        return nil
    end
    if not Schema.PREDICATES[name] then
        reportUnsupported(unsupported,path,'unsupported_condition',{condition=tostring(name)})
        return nil
    end
    return {[name]=value}
end

local function uniqueId(used,wanted,fallback)
    local id=wanted
    if type(id)~='string' or #id==0 or #id>64 then id=fallback end
    id=id:gsub('[^%w_%-]','_'):sub(1,64)
    if used[id] then
        local n=2
        while used[id..'-'..n] do n=n+1 end
        id=id..'-'..n
    end
    used[id]=true
    return id
end

-- Translate one assistant talent entry into a policy rule (or nil + report).
local function translateTalent(entry,index,used,warnings,unsupported)
    local path='talents['..index..']'
    if type(entry)~='table' then
        reportUnsupported(unsupported,path,'invalid_talent_entry')
        return nil
    end
    for key in pairs(entry) do
        if not M.TALENT_KEYS[key] then
            reportUnsupported(unsupported,path,'unsupported_field',{field=tostring(key)})
        end
    end
    local talent=entry.talent
    if type(talent)~='string' then
        reportUnsupported(unsupported,path,'missing_talent')
        return nil
    end
    if entry.enabled==false then return nil,'' end
    if Catalog.isSustain(talent) then
        reportWarning(warnings,path,'talent_is_sustain',{talent=talent})
        return nil
    end
    local descriptor=Catalog.entry(talent)
    if descriptor==nil then
        reportUnsupported(unsupported,path,'unsupported_talent',{talent=talent})
        return nil
    end
    local action=entry.action
    if action==nil then action=talent=='T_ATTACK' and 'attack' or 'use_talent' end
    if not Schema.ACTIONS[action] then
        reportUnsupported(unsupported,path,'unsupported_action',{talent=talent,action=tostring(action)})
        return nil
    end
    if Schema.ACTIVITY_ACTIONS[action] then
        -- Generation never emits native activities or level changes.
        reportUnsupported(unsupported,path,'action_not_generated',{talent=talent,action=action})
        return nil
    end
    local when=translateCondition(entry.when or {always={}},path..'.when',warnings,unsupported,0)
    if when==nil then return nil,'' end
    local target=entry.target
    if target==nil then
        target=descriptor.target=='self' and 'self' or 'nearest_hostile'
    end
    if not Schema.SELECTORS[target] then
        reportWarning(warnings,path,'unsupported_target',{talent=talent,target=tostring(target)})
        target=descriptor.target=='self' and 'self' or 'nearest_hostile'
    end
    local emergency=entry.emergency==true
    if emergency and descriptor.target~='self' then
        reportWarning(warnings,path,'emergency_not_self_preservation',{talent=talent})
        emergency=false
    end
    local priority=entry.priority
    if not finite(priority) or priority<0 or priority>10000 then priority=1000-index end
    local rule={id=uniqueId(used,entry.id,talent:lower():gsub('^t_','')),
        priority=priority,when=when,
        ['then']={action=action,target=target}}
    if action=='use_talent' then rule['then'].talent=talent end
    if emergency then rule.emergency=true end
    return rule
end

-- Translate a pinned assistant export into a policy draft.
function M.translate(config)
    local detected,detect_error=M.detect(config)
    if not detected then return {ok=false,error=detect_error} end
    local warnings,unsupported={},{}
    for key in pairs(config) do
        if not M.CONFIG_KEYS[key] then
            reportUnsupported(unsupported,key,'unsupported_field',{field=tostring(key)})
        end
    end
    local settings=(type(config.settings)=='table') and config.settings or {}
    for key in pairs(settings) do
        if not M.SETTINGS_KEYS[key] then
            reportUnsupported(unsupported,'settings.'..tostring(key),'unsupported_field',{field=tostring(key)})
        end
    end

    local safety={}
    if finite(settings.min_hp_pct) then safety.min_hp_pct=settings.min_hp_pct end
    if finite(settings.flee_below_hp_pct) then safety.flee_below_hp_pct=settings.flee_below_hp_pct end
    if safety.min_hp_pct and safety.flee_below_hp_pct and safety.flee_below_hp_pct>safety.min_hp_pct then
        reportWarning(warnings,'settings.flee_below_hp_pct','flee_above_min_hp',
            {flee=safety.flee_below_hp_pct,min_hp=safety.min_hp_pct})
        safety.flee_below_hp_pct=safety.min_hp_pct
    end
    if type(settings.pause_on_new_enemy)=='boolean' then safety.pause_on_new_enemy=settings.pause_on_new_enemy end
    if type(settings.pause_on_unknown_safety)=='boolean' then safety.pause_on_unknown_safety=settings.pause_on_unknown_safety end
    if finite(settings.max_selffire_risk) then safety.max_selffire_risk=settings.max_selffire_risk end
    local default_target=settings.default_target
    if default_target~=nil and not Schema.SELECTORS[default_target] then
        reportWarning(warnings,'settings.default_target','unsupported_selector',{target=tostring(default_target)})
        default_target=nil
    end

    local sustains={}
    for index,sustain in ipairs(type(config.sustains)=='table' and config.sustains or {}) do
        local path='sustains['..index..']'
        if type(sustain)~='table' then
            reportUnsupported(unsupported,path,'invalid_sustain_entry')
        else
            for key in pairs(sustain) do
                if not M.SUSTAIN_KEYS[key] then
                    reportUnsupported(unsupported,path,'unsupported_field',{field=tostring(key)})
                end
            end
            if sustain.enabled==false then
                -- explicitly disabled: not a warning
            elseif type(sustain.talent)~='string' or not Schema.SUSTAINS[sustain.talent] then
                reportUnsupported(unsupported,path,'unsupported_sustain',{talent=sustain.talent})
            else
                local entry={talent=sustain.talent,
                    priority=finite(sustain.priority) and sustain.priority or 10}
                if finite(sustain.min_resource_pct) then entry.min_resource_pct=sustain.min_resource_pct end
                sustains[#sustains+1]=entry
            end
        end
    end

    local rules,used={},{}
    for index,entry in ipairs(type(config.talents)=='table' and config.talents or {}) do
        local rule=translateTalent(entry,index,used,warnings,unsupported)
        if rule then rules[#rules+1]=rule end
    end

    if #rules==0 then
        return {ok=false,error={code='no_supported_rules',warnings=warnings,unsupported=unsupported}}
    end

    local policy={
        schema=Schema.SCHEMA,
        id=type(config.id)=='string' and config.id or ('assistant-import-'..tostring(config.class or 'unknown')),
        name=type(config.name)=='string' and config.name or 'Assistant import',
        class=type(config.class)=='string' and config.class or nil,
        limits={max_actions_per_tick=finite(settings.max_actions_per_tick)
            and math.floor(settings.max_actions_per_tick) or 1},
        safety=safety,
        targeting={default=default_target or 'nearest_hostile'},
        sustains=sustains,
        rules=rules,
    }
    if policy.class==nil then policy.class=nil end

    local schema_ok,schema_errors=Schema.validate(policy)
    if not schema_ok then
        return {ok=false,error={code='invalid_policy',errors=schema_errors,warnings=warnings,unsupported=unsupported}}
    end
    local compatible,semantic=Catalog.verify(policy)
    if not compatible then
        return {ok=false,error={code='invalid_policy',errors=semantic,warnings=warnings,unsupported=unsupported}}
    end
    return {ok=true,draft=policy,warnings=warnings,unsupported=unsupported,
        version=detected,hash=Schema.hash(policy)}
end

return M
