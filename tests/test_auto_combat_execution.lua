-- Production-path execution tests (Wave 1).
--
-- Unlike the fake `{status='...'}` host outcomes that hid AC-01/AC-03/AC-06,
-- these drive the real `Actions.execute` result through the production mapping
-- helper `Runtime.mapAutoCombatOutcome`. The native compatibility audit is
-- stubbed exactly as tests/test_actions.lua does; the tracker/pending-root
-- mechanics are real.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Runtime=require 'mod.mcp_bridge.Runtime'
local Actions=require 'mod.mcp_bridge.Actions'
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- 1. The production mapping (AC-01/AC-06). -----------------------------------
do
    local pending=Runtime.mapAutoCombatOutcome({ok=true,code='native_pending',energy_spent=0},'use_talent',false)
    check(pending.status=='native_pending','a native_pending result maps to native_pending, not ok')
    check(Runtime.mapAutoCombatOutcome({ok=true,code='action_complete',energy_spent=1000},'use_talent',false).status=='ok',
        'a completed result maps to ok')
    check(Runtime.mapAutoCombatOutcome({ok=true,code='action_complete',energy_spent=0},'use_talent',true).instant==true,
        'no_energy=true plus a zero delta is instant')
    check(Runtime.mapAutoCombatOutcome({ok=true,code='action_complete',energy_spent=0},'use_talent',false).instant==false,
        'no_energy=false is not instant even with a zero delta')
    check(Runtime.mapAutoCombatOutcome({ok=true,code='action_complete',energy_spent=1000},'use_talent',true).instant==false,
        'a positive energy delta is not instant')
    check(Runtime.mapAutoCombatOutcome({ok=true,code='already_in_desired_state',energy_spent=0},'set_sustain',true).instant==false,
        'already_in_desired_state is not an instant action')
    check(Runtime.mapAutoCombatOutcome({ok=false,code='native_rejected',energy_spent=0},'use_talent',false).status=='rejected',
        'a native rejection maps to rejected')
    -- MOV-2: a real scene transition must reach the controller so it can
    -- pause/reset and require an explicit start.
    local change=Runtime.mapAutoCombatOutcome({ok=true,code='level_changed',energy_spent=0,level_changed=true},
        'change_level',nil)
    check(change.status=='ok' and change.level_changed==true,
        'a change_level scene transition is preserved in the production mapping')
    local pendingChange=Runtime.mapAutoCombatOutcome({ok=true,code='change_level_pending',
        energy_spent=0,level_changed=false},'change_level',nil)
    check(pendingChange.status=='rejected' and pendingChange.code=='change_level_pending',
        'a pending scene confirmation is handed back, not reported as a completed transition')
end

-- 2. Real Actions.execute -> a suspended body yields native_pending. ---------
do
    local matches,check_compat=Compat.matches,Compat.check
    Compat.matches=function(name,fn) if name=='useTalent' then return true end return matches(name,fn) end
    Compat.check=function() return true end
    Tracker.reset(function() end)
    local p={__is_actor=true,x=1,y=1,energy={value=1000},talents={T_EXAMPLE=1},
        talents_def={T_EXAMPLE={id='T_EXAMPLE',mode='activated',cooldown=0,action=function() end}}}
    local g={player=p,level={}}
    function p:useTalent()
        return Tracker.call(p,'T_EXAMPLE',function()
            local co=Tracker.createBody(function() coroutine.yield('pending');return true end)
            assert(coroutine.resume(co))
        end)
    end
    local command={command_id='c1'}
    local result=Actions.execute(g,{type='use_talent',talent_id='T_EXAMPLE'},nil,{},command)
    check(result.ok==true and result.code=='native_pending',
        'the real Actions.execute reports native_pending for a suspended native body')
    check(command.invocation~=nil and command.invocation.pending>0 and not command.invocation.done,
        'the real production root stays pending')
    local mapped=Runtime.mapAutoCombatOutcome(result,'use_talent',false)
    check(mapped.status=='native_pending','the production mapping preserves the real native_pending')
    if command.invocation then Tracker.release(command.invocation) end
    Compat.matches,Compat.check=matches,check_compat
end

print('Auto-combat execution: '..checks..' checks passed')
