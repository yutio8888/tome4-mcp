-- GPL-3.0-or-later. Pure view model for the in-game policy editor.
--
-- The editor must work with no MCP client attached: pick a preset, edit, save,
-- start and stop. The engine Dialog is a thin renderer over this model, so the
-- availability rules (what can be pressed, and why not) are unit tested without
-- the engine.
local M={}

-- status: the AutoCombatService status payload (ok already stripped), plus an
-- optional `run` block: {state,reason,generation,attempts}.
function M.options(status)
    status=status or {}
    local run=status.run
    local running=run~=nil and run.state~='stopped'
    local options={
        {id='preset',label='Load preset',enabled=true,
            reason=status.has_presets==false and 'no_presets' or nil},
        {id='activate',label='Activate approved policy',
            enabled=(status.approved_hash~=nil and status.active~=true),
            reason=status.approved_hash==nil and 'not_approved' or (status.active and 'already_active') or nil},
        {id='deactivate',label='Deactivate',enabled=status.active==true,
            reason=status.active~=true and 'not_active' or nil},
        {id='start',label='Start',enabled=(status.running_hash~=nil and not running),
            reason=status.running_hash==nil and 'not_activated' or (running and 'already_running') or nil},
        {id='stop',label='Stop',enabled=running,
            reason=not running and 'not_running' or nil},
        {id='pause',label='Pause',enabled=running and run.state~='paused',
            reason=not running and 'not_running' or (running and run.state=='paused' and 'already_paused') or nil},
        {id='resume',label='Resume',enabled=running and run.state=='paused',
            reason=(not running or run.state~='paused') and 'not_paused' or nil},
        {id='export',label='Export policy',enabled=(status.draft_hash or status.approved_hash)~=nil,
            reason=(status.draft_hash or status.approved_hash)==nil and 'no_policy' or nil},
    }
    return options
end

function M.lines(status)
    status=status or {}
    local run=status.run or {}
    local function short(hash) return hash and hash:sub(1,8) or 'none' end
    return {
        'Policy: draft '..short(status.draft_hash)..'  approved '..short(status.approved_hash)
            ..'  running '..short(status.running_hash),
        'Control: '..(status.control_owner or 'manual')..(status.actionable and ' (actionable)' or ''),
        'Run: '..(run.state or 'stopped')..(run.reason and (' ('..run.reason..')') or '')
            ..(run.generation and (' gen '..run.generation) or ''),
        'Strict: '..(status.strict and 'on' or 'off'),
    }
end

-- Map an editor action to a service operation. `preset_name` is optional and
-- only used by the preset action.
function M.request(action,preset_name)
    if action=='preset' then return 'preset',{name=preset_name} end
    if action=='activate' or action=='deactivate' or action=='start' or action=='stop'
        or action=='pause' or action=='resume' or action=='export' then
        return action,{}
    end
    return nil,nil
end

function M.canApply(status,action)
    for _,option in ipairs(M.options(status)) do
        if option.id==action then return option.enabled,option.reason end
    end
    return false,'unknown_action'
end

-- Editing ---------------------------------------------------------------------
-- The editor edits one draft at a time. Every mutation is a pure clone -> edit
-- -> new policy, so the UI never keeps a second copy of the data and the same
-- functions are unit tested without the engine.
function M.clone(value)
    if type(value)~='table' then return value end
    local out={}
    for key,item in pairs(value) do out[key]=M.clone(item) end
    return out
end

local function ruleOf(policy,id)
    for _,rule in ipairs((policy and policy.rules) or {}) do
        if rule.id==id then return rule end
    end
    return nil
end

-- D-3: the canonical new-enemy choice is the mode field. The editor exposes
-- one boolean and keeps the legacy `safety.pause_on_new_enemy` coherent.
local function newEnemyPause(policy)
    local mode=(policy and policy.mode) or {}
    local safety=(policy and policy.safety) or {}
    if mode.on_new_enemy~=nil then return mode.on_new_enemy=='pause' end
    return safety.pause_on_new_enemy~=false
end
M.newEnemyPause=newEnemyPause

-- Field descriptor: {id,group,rule,label,kind,value,min,max}. `kind` is
-- 'integer' | 'number' | 'boolean'. Rules are listed after the global fields.
function M.fields(policy)
    policy=policy or {}
    local limits=policy.limits or {}
    local safety=policy.safety or {}
    local fields={
        {id='limits.max_actions_per_tick',group='limits',label='Actions per tick',
            kind='integer',value=limits.max_actions_per_tick or 1,min=1,max=4},
        {id='safety.min_hp_pct',group='safety',label='Min HP %',
            kind='number',value=safety.min_hp_pct,min=0,max=100},
        {id='safety.flee_below_hp_pct',group='safety',label='Flee below HP %',
            kind='number',value=safety.flee_below_hp_pct,min=0,max=100},
        {id='mode.on_new_enemy',group='mode',label='Pause on new enemy',
            kind='boolean',value=newEnemyPause(policy)},
        {id='safety.pause_on_unknown_safety',group='safety',label='Pause on unknown safety',
            kind='boolean',value=safety.pause_on_unknown_safety~=false},
    }
    for _,rule in ipairs(policy.rules or {}) do
        fields[#fields+1]={id='rules.'..rule.id..'.enabled',group='rule',rule=rule.id,
            label=rule.id,kind='boolean',value=rule.enabled~=false}
        fields[#fields+1]={id='rules.'..rule.id..'.priority',group='rule',rule=rule.id,
            label=rule.id..' priority',kind='integer',value=rule.priority or 0,min=0,max=10000}
    end
    return fields
end

local function fieldKind(field)
    if field.group=='limits' then return 'limits',field.id:match('%.([%w_]+)$') end
    if field.group=='safety' then return 'safety',field.id:match('%.([%w_]+)$') end
    if field.group=='mode' then return 'mode',field.id:match('%.([%w_]+)$') end
    if field.group=='rule' then return 'rule',field.rule,field.id:match('%.([%w_]+)$') end
    return nil
end
M.fieldKind=fieldKind

-- Toggle a boolean field. Returns the new policy, or nil + error.
function M.toggle(policy,field_id)
    local field
    for _,candidate in ipairs(M.fields(policy)) do
        if candidate.id==field_id then field=candidate break end
    end
    if not field or field.kind~='boolean' then return nil,{code='not_boolean',field=field_id} end
    local updated=M.clone(policy)
    local scope=fieldKind(field)
    if scope=='limits' then return nil,{code='read_only',field=field_id} end
    if scope=='mode' then
        local key=field.id:match('%.([%w_]+)$')
        updated.mode=updated.mode or {}
        local pause=not field.value
        updated.mode[key]=pause and 'pause' or 'continue'
        if key=='on_new_enemy' then
            updated.safety=updated.safety or {}
            updated.safety.pause_on_new_enemy=pause
        end
    elseif scope=='safety' then
        local key=field.id:match('%.([%w_]+)$')
        updated.safety=updated.safety or {}
        updated.safety[key]=not field.value
    elseif scope=='rule' then
        local key=field.id:match('%.([%w_]+)$')
        local rule=ruleOf(updated,field.rule)
        if not rule then return nil,{code='unknown_rule',rule=field.rule} end
        if key=='enabled' then rule.enabled=not field.value end
    end
    return updated
end

-- Increment/decrement a numeric field, clamped to its bounds. Returns the new
-- policy, or nil + error.
function M.bump(policy,field_id,delta)
    local field
    for _,candidate in ipairs(M.fields(policy)) do
        if candidate.id==field_id then field=candidate break end
    end
    if not field or (field.kind~='integer' and field.kind~='number') then
        return nil,{code='not_numeric',field=field_id}
    end
    delta=delta or 0
    local updated=M.clone(policy)
    local scope=fieldKind(field)
    local function clamp(value)
        if field.min and value<field.min then value=field.min end
        if field.max and value>field.max then value=field.max end
        return value
    end
    if scope=='limits' then
        local key=field.id:match('%.([%w_]+)$')
        updated.limits=updated.limits or {}
        updated.limits[key]=clamp((field.value or 0)+delta)
    elseif scope=='safety' then
        local key=field.id:match('%.([%w_]+)$')
        updated.safety=updated.safety or {}
        updated.safety[key]=clamp((field.value or 0)+delta)
    elseif scope=='rule' then
        local key=field.id:match('%.([%w_]+)$')
        local rule=ruleOf(updated,field.rule)
        if not rule then return nil,{code='unknown_rule',rule=field.rule} end
        if key=='priority' then rule.priority=clamp((field.value or 0)+delta) end
    end
    return updated
end
return M
