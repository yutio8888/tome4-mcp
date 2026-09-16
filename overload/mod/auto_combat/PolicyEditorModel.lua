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
return M
