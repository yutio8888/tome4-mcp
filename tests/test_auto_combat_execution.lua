-- Production-path execution tests (Wave 1).
--
-- Unlike the fake `{status='...'}` host outcomes that hid AC-01/AC-03/AC-06,
-- these drive the real `Actions.execute` result through the production mapping
-- helper `Runtime.mapAutoCombatOutcome`. The native compatibility audit is
-- stubbed exactly as tests/test_actions.lua does; the tracker/pending-root
-- mechanics are real.
-- P3-b (TODO #63): derive the addon root from this test's own path so a bare
-- relative invocation fails loudly instead of silently testing the canonical
-- `game/addons/tome-mcp-bridge` tree from another checkout.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
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
    -- D-2: the structured refusal detail is preserved through the production
    -- mapping so the auto policy log carries the same evidence as tome.act.
    local detailed=Runtime.mapAutoCombatOutcome({ok=false,code='native_rejected',energy_spent=0,
        missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=7,required=0}},
        hint='talent on cooldown; wait for the listed turns before retrying',
        native_message='Healing Light is still on cooldown for 7 turns.'},'use_talent',false)
    check(detailed.status=='rejected' and detailed.missing and detailed.missing[1].kind=='cooldown'
        and detailed.missing[1].remaining==7,
        'the production mapping preserves the structured cooldown missing (D-2)')
    check(detailed.native_message=='Healing Light is still on cooldown for 7 turns.'
        and type(detailed.hint)=='string',
        'the production mapping preserves the native message and hint (D-2)')
    check(Runtime.mapAutoCombatOutcome({ok=false,code='native_rejected',energy_spent=0},
        'use_talent',false).missing==nil,
        'a refusal without structured detail adds no missing field (D-2)')
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
    -- MFT-REV-06: scene-change evidence survives an uncertain outcome, so the
    -- controller stops/resets instead of leaving a resumable paused run.
    local uncertainChange=Runtime.mapAutoCombatOutcome({ok=false,code='execution_error',
        energy_spent=0,uncertain=true,level_changed=true},'change_level',nil)
    check(uncertainChange.status=='uncertain' and uncertainChange.level_changed==true,
        'an uncertain exception preserves level_changed for the controller')
    local uncertainNoChange=Runtime.mapAutoCombatOutcome({ok=false,code='execution_error',
        energy_spent=0,uncertain=true,level_changed=false},'change_level',nil)
    check(uncertainNoChange.status=='uncertain' and uncertainNoChange.level_changed==nil,
        'an uncertain exception without a transition stays a plain uncertain outcome')
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

-- S3 S-U4/G-U7/V-U5 (runtime layer): the pure postcondition evaluation. The
-- Shadowstep fizzle mode is a settled pass; an unchanged endpoint with
-- `unchanged='mismatch'` (Giant Leap/Vault) is a mismatch; success inside the
-- deterministic/bounded/random envelope passes; outside every declared
-- primary/fallback envelope, a missing endpoint or a malformed expectation is a
-- typed movement_postcondition_mismatch.
do
    local function checkPost(exp,endp,outcome)
        local mismatch=Runtime.movementPostconditionMismatch(exp,endp)
        if outcome==nil then
            check(mismatch==nil,'expected the postcondition to pass: '..tostring(outcome))
        else
            check(mismatch~=nil and mismatch.reason=='movement_postcondition_mismatch'
                and mismatch.uncertain==true and mismatch.outcome==outcome,
                'expected mismatch '..tostring(outcome),mismatch and mismatch.outcome)
        end
        return mismatch
    end
    -- Shadowstep: unchanged endpoint + unchanged='fizzle' is a settled pass.
    local shadowstep={talent='T_SHADOWSTEP',mover='self',unchanged='fizzle',
        before={x=2,y=2},landing={kind='bounded',center={x=5,y=2},radius=5}}
    checkPost(shadowstep,{x=2,y=2},nil)
    checkPost(shadowstep,{x=5,y=2},nil)
    checkPost(shadowstep,{x=5,y=7},nil)
    checkPost(shadowstep,{x=20,y=2},'outside_landing_envelope')
    -- Giant Leap: the requested-grid envelope is radius 1 around the request;
    -- an unchanged endpoint is a mismatch.
    local leap={talent='T_GIANT_LEAP',mover='self',unchanged='mismatch',
        before={x=2,y=2},landing={kind='bounded',center={x=6,y=2},radius=1}}
    checkPost(leap,{x=6,y=2},nil)
    checkPost(leap,{x=7,y=3},nil)  -- distance grid <= 1
    checkPost(leap,{x=2,y=2},'unchanged_endpoint')
    checkPost(leap,{x=9,y=2},'outside_landing_envelope')
    -- A deterministic envelope is a single cell.
    local exact={talent='T_VAULT',mover='self',unchanged='mismatch',
        before={x=2,y=2},landing={kind='deterministic',center={x=4,y=2},radius=0}}
    checkPost(exact,{x=4,y=2},nil)
    checkPost(exact,{x=4,y=3},'outside_landing_envelope')
    -- A declared LOS fallback is part of the envelope.
    local fallback={talent='T_VAULT',mover='self',unchanged='mismatch',
        before={x=2,y=2},landing={kind='bounded',center={x=6,y=2},radius=1,
            fallback={kind='random',center={x=2,y=2},radius=5}}}
    checkPost(fallback,{x=4,y=4},nil)
    checkPost(fallback,{x=20,y=20},'outside_landing_envelope')
    -- Missing endpoint and malformed expectation fail closed.
    checkPost(leap,{},'endpoint_missing')
    checkPost({talent='T_VAULT',mover='self'},{x=4,y=2},'malformed_expectation')
end

print('Auto-combat execution: '..checks..' checks passed')
