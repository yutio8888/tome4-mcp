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
local Json=require 'mod.mcp_bridge.Json'
local Owned=require 'mod.auto_combat.OwnedImport'
local Codec=require 'mod.auto_combat.PolicyCodec'
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

-- Version tuple. X-prime slice 1: the tuple MUST be a dense table. A scalar or
-- any other non-table is a fault with `cause='not_array'` — the previously
-- shipped `tostring(v)` shortcut let an exact pinned scalar version (for
-- example the string '2.3.9') be accepted and stored. Returns the joined key,
-- or `nil, cause, key` on a fault.
function M.versionKey(v)
    if type(v)=='table' and v~=Json.null then
        local dense,count=Json.denseArray(v,0)
        if dense then
            local parts={}
            for i=1,count do parts[#parts+1]=tostring(v[i]) end
            return table.concat(parts,'.')
        end
        return nil,Json.denseFault(v)
    end
    return nil,'not_array'
end

-- A typed whole-import fault naming the malformed input, its cause and (when
-- the shape has one) the offending key. One vocabulary for every ingress.
local function inputFault(input,cause,key)
    local out={code='invalid_document',input=input,cause=cause or 'not_array'}
    if key~=nil then out.key=key end
    return out
end
M.inputFault=inputFault

-- Pin check on an ALREADY validated private tree (internal).
local function detectValidated(config)
    if type(config)~='table' then return nil,{code='not_a_table'} end
    local assistant=config.assistant
    if type(assistant)~='table' then return nil,{code='missing_assistant'} end
    if assistant.addon~=M.PINNED.addon then
        return nil,{code='unknown_addon',expected=M.PINNED.addon,got=assistant.addon}
    end
    local got,gotCause,gotKey=M.versionKey(assistant.addon_version)
    if got==nil then
        return nil,inputFault('assistant.addon_version',gotCause or 'not_array',gotKey)
    end
    if got~=M.PINNED.addon_version then
        return nil,{code='assistant_version_mismatch',expected=M.PINNED.addon_version,got=got}
    end
    if config.format~=M.FORMAT then
        return nil,{code='unsupported_format',expected=M.FORMAT,got=config.format}
    end
    local tomeStr,tomeCause,tomeKey=M.versionKey(assistant.tome_version)
    if tomeStr==nil then
        return nil,inputFault('assistant.tome_version',tomeCause or 'not_array',tomeKey)
    end
    return {version=got,addon=assistant.addon,addon_version=got,
        tome_version=tomeStr,format=config.format}
end
M.detectValidated=detectValidated

-- Pin check on raw caller input. X-doubleprime: there is no owned type any
-- more, so the raw input is ALWAYS reconstructed (audited + schema-row
-- validated) here; a caller table is never trusted.
function M.detect(config)
    if type(config)~='table' or config==Json.null then return nil,{code='not_a_table'} end
    local owned,fault=Owned.construct(config)
    if not owned then return nil,fault end
    return detectValidated(owned)
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
-- than silently weakening the condition). A structurally MALFORMED `all`/`any`
-- array is different: it returns `nil, fault`, which TERMINATES the whole
-- import (the previous behaviour merely dropped the one rule, leaving a
-- hashed/stored policy that silently lost a condition).
local function translateCondition(cond,path,warnings,unsupported,depth)
    depth=depth or 0
    if depth>Schema.HARD.max_depth then
        -- XPS1-REV-03: a condition nested beyond the hard depth is a typed
        -- WHOLE-IMPORT fault ({code,input,cause,key}; for a depth fault the key
        -- is the offending depth). It is never degraded to a plain `nil`
        -- (which previously became an empty-string rule and an untyped error).
        return nil,inputFault(path,'condition_too_deep',depth)
    end
    if type(cond)~='table' then
        return nil,inputFault(path,'not_a_table')
    end
    if cond.all~=nil or cond.any~=nil then
        local key=cond.all~=nil and 'all' or 'any'
        local list=cond[key]
        local dense,countOrCause=Json.denseArray(list,0)
        if not dense then
            local cause,offendingKey=Json.denseFault(list)
            return nil,inputFault(path..'.'..key,cause or countOrCause,offendingKey)
        end
        local count=countOrCause
        local out={}
        for index=1,count do
            local translated,fault=translateCondition(list[index],
                path..'.'..key..'['..index..']',warnings,unsupported,depth+1)
            if fault then return nil,fault end
            if translated==nil then return nil end
            out[#out+1]=translated
        end
        return {[key]=out}
    end
    if cond['not']~=nil then
        local translated,fault=translateCondition(cond['not'],path..'.not',warnings,unsupported,depth+1)
        if fault then return nil,fault end
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
-- XPS1-REV-03: a non-table element is a MALFORMED element — a typed
-- whole-import fault naming the list, the cause and the offending index. It is
-- never "unsupported ⇒ continue": a non-table entry cannot be interpreted as
-- an assistant entry at all, so continuing would manufacture a partial
-- artifact (the review's partial draft + revision advance).
local function translateTalent(entry,index,used,warnings,unsupported)
    local path='talents['..index..']'
    if type(entry)~='table' or entry==Json.null then
        return nil,inputFault('talents','invalid_element',index)
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
    if entry.enabled==false then return nil end
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
    local when,fault=translateCondition(entry.when or {always={}},path..'.when',warnings,unsupported,0)
    if fault then return nil,fault end
    if when==nil then return nil end
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
    -- X-doubleprime: the raw caller table never reaches translation. The ONLY
    -- constructor that accepts raw input audits the COMPLETE original structure
    -- (nothing dropped, no lossy pre-copy) and validates its schema rows BEFORE
    -- any density/element read; any malformed required array or element refuses
    -- the WHOLE import here — before any draft, hash or store exists.
    local owned,fault=Owned.construct(config)
    if not owned then return {ok=false,error=fault} end
    config=owned
    local detected,detect_error=M.detectValidated(config)
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
    -- Dense/closed validation over ALL keys before any `#`/`ipairs`; the
    -- constructor already refused a malformed list, so this is the same single
    -- vocabulary applied at the consumer. A hole can never be read as a
    -- shorter prefix.
    local sustainsValid,sustainsCause=Json.denseArray(config.sustains,0)
    if config.sustains~=nil and not sustainsValid then
        local cause,offendingKey=Json.denseFault(config.sustains)
        return {ok=false,error=inputFault('sustains',cause or sustainsCause,offendingKey)}
    end
    local sustainsList=sustainsValid and config.sustains or nil
    for index,sustain in ipairs(sustainsList or {}) do
        local path='sustains['..index..']'
        -- XPS1-REV-03: same element-shape rule as talents — a non-table
        -- sustain element refuses the WHOLE import with the typed fault.
        if type(sustain)~='table' or sustain==Json.null then
            return {ok=false,error=inputFault('sustains','invalid_element',index)}
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
    local talentsValid,talentsCause=Json.denseArray(config.talents,0)
    if config.talents~=nil and not talentsValid then
        local cause,offendingKey=Json.denseFault(config.talents)
        return {ok=false,error=inputFault('talents',cause or talentsCause,offendingKey)}
    end
    local talentsList=talentsValid and config.talents or nil
    for index,entry in ipairs(talentsList or {}) do
        local rule,ruleFault=translateTalent(entry,index,used,warnings,unsupported)
        if ruleFault then return {ok=false,error=ruleFault} end
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
    -- X-doubleprime: bind the generated draft to canonical bytes BEFORE it
    -- leaves the importer, so the hash the result reports is the hash of the
    -- snapshot's validated content (not a projection later re-run on a mutable
    -- caller table).
    local snapshot,err=M.policySnapshot(policy,'import_assistant')
    if not snapshot then
        return {ok=false,error=err.code=='invalid_policy' and
            {code='invalid_policy',errors=err.errors,warnings=warnings,unsupported=unsupported}
            or err}
    end
    return {ok=true,draft=assert(Codec.open(snapshot)),snapshot=snapshot,
        warnings=warnings,unsupported=unsupported,version=detected,hash=snapshot.hash}
end

-- X-doubleprime — the ONE policy snapshot transaction every hash/evaluate/store
-- sink runs. There is no ownership registry and no value cache: the input is
-- ALWAYS audited+validated before it is encoded, and the immutable bytes (not
-- the table) are what downstream state binds. A raw caller table — including a
-- policy that lost ownership across an ordinary MCP round-trip — works; a
-- malformed one is refused typed before any hash/encode/store. A snapshot
-- record is accepted directly: its bytes are immutable and its content is
-- re-validated under the CURRENT schema by the consumer's `Codec.open`.
--
-- This replaces the X-prime table-identity mechanism (XPS1-R2-01): identity
-- proved a past check, not the current value, so any later edit of a returned
-- copy — schema-valid or not — could change an approved/running policy.
function M.policySnapshot(policy,sink)
    if Codec.isSnapshot(policy) then
        local tree,err=Codec.open(policy)
        if not tree then return nil,err end
        return policy
    end
    return Codec.prepare(policy,sink or 'policy')
end

-- Legacy name for the same transaction (XPS1-R2-01 closes through the bytes).
M.ownPolicy=M.policySnapshot

-- A raw policy hash: validates first, then projects. Kept for callers that
-- only need a digest; a malformed value raises a typed error rather than being
-- hashed (XPS1-R2-03).
function M.hashPolicy(policy)
    local snapshot,err=M.policySnapshot(policy,'hash')
    if not snapshot then error(err and (err.code or 'invalid_policy') or 'invalid_policy',2) end
    return snapshot.hash
end

return M
