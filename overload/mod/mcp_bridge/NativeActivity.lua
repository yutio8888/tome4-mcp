-- GPL-3.0-or-later. Generic multi-turn native activity registry (P1b).
--
-- `rest` and `auto_explore` are multi-turn native processes: they are started
-- once, advance across world turns, may own their own popup (the rest dialog /
-- the "Running..." auto-explore dialog) and have a stop/interrupt path. This
-- module is the single description of that lifecycle so Runtime and the
-- auto-combat executor express both activities through the same records instead
-- of ad-hoc `action.type` branches.
--
-- An activity record is a plain table. For MCP commands the record *is* the
-- command (its existing `native_rest`/`rest_dialog`/`native_run`/`run_dialog`
-- fields are reused verbatim); for the auto-combat controller the record is a
-- small standalone table with the same fields. Either way:
--
--   activity.kind          'rest' | 'auto_explore'
--   activity.owner         'command' | 'auto_combat'
--   activity.native_rest   the p.resting handle (rest only)
--   activity.native_run    the p.running handle (auto_explore only)
--   activity.rest_dialog   owned rest popup
--   activity.run_dialog    owned run popup
--   activity.turns_executed / max_turns / stopping / stop_error / stop_reason
--
-- The session holds at most one: `s.native_activity`.
local Details=require 'mod.mcp_bridge.ObservationDetails'
local Observer=require 'mod.mcp_bridge.Observer'
local M={}

M.KINDS={rest=true,auto_explore=true}

function M.is(kind) return kind~=nil and M.KINDS[kind]==true end

function M.nativeRef(activity)
    if not activity then return nil end
    if activity.kind=='rest' then return activity.native_rest end
    if activity.kind=='auto_explore' then return activity.native_run end
end

function M.dialog(activity)
    if not activity then return nil end
    if activity.kind=='rest' then return activity.rest_dialog end
    return activity.run_dialog
end

function M.live(activity, player)
    local ref=M.nativeRef(activity)
    if not ref or not player then return false end
    if activity.kind=='rest' then return player.resting==ref end
    if activity.kind=='auto_explore' then return player.running==ref end
    return false
end

-- Who currently holds the action lease for this activity.
function M.holds(s, activity)
    if not activity then return false end
    if activity.owner=='auto_combat' then
        return s.auto_combat and s.auto_combat.arbiter and s.auto_combat.arbiter.owner=='auto_combat'
    end
    local command=activity.command
    return s.control_token~=nil and command~=nil and command.input_owner=='remote'
end

-- The native RUN_AUTO guard is reactionToward(actor) < 0. A visible escort or
-- summon is not hostile, so it must not refuse auto-explore.
-- NO-AUDIT: the live `reactionToward` is called as a normal entry when present
-- and usable; a missing/erroring/non-numeric result falls back to the stored
-- scalar/faction classification. Source identity never changes the decision.
function M.hostileVisible(g,p,actor)
    if actor==p or type(actor)~='table' or not actor.__is_actor or not Observer.visible(g,actor) then return false end
    if type(p.reactionToward)=='function' then
        local ok,r=pcall(p.reactionToward,p,actor)
        if ok and type(r)=='number' then return r<0 end
    end
    if type(actor.reaction)=='number' then return actor.reaction<0 end
    return actor.faction~=nil and actor.faction~=p.faction
end

-- A failed native activity cleanup leaves native state the bridge cannot
-- repair: mark it uncertain, quarantine automatic steps, and (for a command
-- owner) revoke the remote lease rather than pretending success.
local function fault(s, activity)
    activity.stop_error=true;activity.uncertain=true
    s.native_error=s.native_error or (activity.kind=='auto_explore' and 'native_run_stop_error' or 'native_rest_stop_error')
    if activity.kind=='rest' then
        s.failed_rest=s.game and s.game.player and s.game.player.resting
    end
    if activity.owner~='auto_combat' and activity.kind=='rest' and s.control_token then
        s.control_token=nil;s.revision=(s.revision or 0)+1
    end
end

-- Descriptors ---------------------------------------------------------------
local rest={
    kind='rest',label='task.rest',
    guards=function(env)
        local p=env.player
        if type(p.restInit)~='function' then return {ok=false,code='rest_unavailable',energy_spent=0} end
    end,
    start=function(env,activity,options)
        local s,p=env.session,env.player
        activity.max_turns=options and options.max_turns
        local energy=p.energy.value
        s.starting_rest=true
        local ok,err=pcall(p.restInit,p)
        s.starting_rest=false
        activity.native_rest=p.resting or activity.native_rest
        if activity.native_rest then activity.turns_executed=activity.native_rest.cnt or 0 end
        local result={ok=ok,code=ok and 'rest_complete' or 'execution_error',
            energy_spent=math.max(0,energy-p.energy.value)}
        if not ok then result.uncertain=true;result.native_message=Details.text(tostring(err),512) end
        return result
    end,
    stop=function(env,activity,reason)
        local p=env.player
        if p and p.resting and p.resting==activity.native_rest then
            activity.turns_executed=p.resting.cnt or 0
            activity.stopping=true
            local ok,err=pcall(p.restStop,p,reason)
            activity.stopping=false
            if not ok then
                activity.stop_error=true;activity.uncertain=true
                fault(env.session,activity)
            end
        end
    end,
}

local auto_explore={
    kind='auto_explore',label='task.auto_explore',
    guards=function(env)
        local p,g=env.player,env.game
        if type(p.autoExplore)~='function' or type(p.runStep)~='function'
            or type(p.enoughEnergy)~='function' then
            return {ok=false,code='auto_explore_unavailable',energy_spent=0}
        end
        if (g.zone and g.zone.no_autoexplore) or (g.level and g.level.no_autoexplore) then
            return {ok=false,code='no_autoexplore',native_message='You may not auto-explore this level.',energy_spent=0}
        end
        for _,actor in pairs(g.level and g.level.entities or {}) do
            if M.hostileVisible(g,p,actor) then
                return {ok=false,code='enemies_in_sight',
                    native_message='You may not auto-explore with enemies in sight ('
                        ..(Details.text(actor.name,48) or 'hostile')..').',energy_spent=0,
                    hint='defeat or lose sight of the hostile first; escorts and allies do not block auto-explore'}
            end
        end
    end,
    start=function(env,activity)
        local s,p,g=env.session,env.player,env.game
        local energy=p.energy.value
        local ok,started=pcall(p.autoExplore,p)
        if not ok then
            return {ok=false,code='execution_error',uncertain=true,
                native_message=Details.text(tostring(started),512),energy_spent=0}
        end
        activity.native_run=p.running
        activity.run_dialog=p.running and p.running.dialog or nil
        if not activity.native_run then
            return {ok=false,code='nothing_left',native_message='There is nowhere left to explore.',
                energy_spent=math.max(0,energy-p.energy.value)}
        end
        local start_x,start_y=p.x,p.y
        local steps=0
        local ok2,err=pcall(function()
            while steps<200 and p:enoughEnergy() and p:runStep() do steps=steps+1 end
        end)
        if not ok2 then
            return {ok=false,code='execution_error',uncertain=true,
                native_message=Details.text(tostring(err),512),energy_spent=math.max(0,energy-p.energy.value)}
        end
        if not p.running then
            -- The run ended within the first opportunity: report the real reason
            -- instead of a bare "exploring" that leaves the caller spinning.
            for _,actor in pairs(g.level and g.level.entities or {}) do
                if M.hostileVisible(g,p,actor) then
                    return {ok=false,code='enemies_in_sight',
                        native_message='You may not auto-explore with enemies in sight ('
                            ..(Details.text(actor.name,48) or 'hostile')..').',
                        energy_spent=math.max(0,energy-p.energy.value),
                        hint='defeat or lose sight of the hostile first; escorts and allies do not block auto-explore'}
                end
            end
            if p.x==start_x and p.y==start_y then
                return {ok=false,code='nothing_left',native_message='There is nowhere left to explore.',
                    energy_spent=math.max(0,energy-p.energy.value)}
            end
            return {ok=true,code='explore_stopped',
                native_message='native auto-explore stopped; observe interaction/dialogs before continuing',
                energy_spent=math.max(0,energy-p.energy.value)}
        end
        return {ok=true,code='exploring',energy_spent=math.max(0,energy-p.energy.value)}
    end,
    stop=function(env,activity,reason)
        local p=env.player
        if p and p.running and (not activity.native_run or p.running==activity.native_run)
            and type(p.runStop)=='function' then
            activity.stopping=true
            local ok,err=pcall(p.runStop,p,reason)
            activity.stopping=false
            if not ok then
                activity.stop_error=true;activity.uncertain=true
                fault(env.session,activity)
            end
        end
    end,
}

M.descriptors={rest=rest,auto_explore=auto_explore}
function M.descriptor(kind) return M.descriptors[kind] end
function M.label(kind) local d=M.descriptors[kind]; return d and d.label or kind end

-- Lifecycle -----------------------------------------------------------------
-- Register `activity` as the session's current activity and start it. The
-- activity may be an MCP command (owner='command', fields are its own) or a
-- standalone auto-combat record (owner='auto_combat').
function M.start(s, activity, kind, options)
    local descriptor=M.descriptors[kind]
    if not descriptor then return {ok=false,code='unsupported_native_activity',energy_spent=false} end
    activity.kind=kind
    activity.owner=activity.owner or 'command'
    activity.command=activity.command or (activity.owner=='command' and activity or nil)
    s.native_activity=activity
    local env={session=s,player=s.game and s.game.player,game=s.game,activity=activity}
    if descriptor.guards then
        local refusal=descriptor.guards(env)
        if refusal then refusal.energy_spent=refusal.energy_spent or false;return refusal end
    end
    return descriptor.start(env,activity,options)
end

function M.stop(s, activity, reason)
    if not activity or activity.stopping or activity.stop_error then return end
    activity.stop_reason=activity.stop_reason or reason
    local descriptor=M.descriptors[activity.kind]
    if descriptor and descriptor.stop then
        descriptor.stop({session=s,player=s.game and s.game.player,game=s.game,activity=activity},activity,reason)
    end
    if activity.stop_error then fault(s,activity) end
end

-- Rest per-step gate: budget, lease and failed-cleanup quarantine.
function M.beforeStep(s, player)
    local activity=s and s.native_activity
    if not activity or activity.kind~='rest' then return true end
    if s.failed_rest and player.resting==s.failed_rest then return false end
    if player~=s.game.player or not player.resting or player.resting~=activity.native_rest then return true end
    activity.turns_executed=player.resting.cnt or 0
    if not M.holds(s,activity) then M.stop(s,activity,'control_lost');return false end
    if activity.max_turns and activity.turns_executed>=activity.max_turns then
        M.stop(s,activity,'max_turns');return false
    end
    return true
end

function M.afterStep(s, player, energy_before)
    local activity=s and s.native_activity
    if activity and activity.kind=='rest' and player==s.game.player and activity.native_rest then
        activity.turns_executed=activity.native_rest.cnt or 0
        activity.energy_spent=(activity.energy_spent or 0)+math.max(0,energy_before-player.energy.value)
    end
end

function M.markInterruption(s, reason)
    local activity=s and s.native_activity
    if activity and activity.kind=='rest' and s.game.player and s.game.player.resting
        and s.game.player.resting==activity.native_rest then
        activity.stop_reason=activity.stop_reason or reason
    end
end

-- Called from the wrapped `restStop` before the native method. Returns the
-- activity and the previous `stopping` flag so the caller can restore it.
function M.onStop(s, player, message)
    local activity=s and s.native_activity
    if not activity or activity.kind~='rest' or player~=s.game.player or not player.resting then return end
    if player.resting~=activity.native_rest then
        if not s.starting_rest or player.resting.dialog~=activity.rest_dialog then return end
        activity.native_rest=player.resting
    end
    activity.turns_executed=player.resting.cnt or 0
    activity.native_message=Details.text(message,512)
    activity.stop_reason=activity.stop_reason or (player.resting.rested_fully and 'native_complete' or 'native_stopped')
    local was_stopping=activity.stopping
    activity.stopping=true
    return activity,was_stopping
end

function M.afterStop(activity, was_stopping)
    if activity then activity.stopping=was_stopping end
end

function M.onStopError(s, activity)
    if s and activity and s.native_activity==activity then fault(s,activity) end
end

-- Dialog ownership. Returns:
--   'owned'      the popup belongs to this activity (already or just claimed)
--   'passive'    the run popup, adopt it as a passive dialog
--   nil          not ours
function M.ownsDialog(s, activity, dialog, enter)
    if not activity or not dialog then return nil end
    if activity.kind=='rest' then
        if enter and s.starting_rest and not activity.rest_dialog then activity.rest_dialog=dialog;return 'owned' end
        if dialog==activity.rest_dialog then return 'owned' end
        return nil
    end
    if dialog==activity.run_dialog then return 'owned' end
    if enter and activity.native_run and activity.native_run.dialog==dialog then
        activity.run_dialog=dialog
        return 'passive'
    end
    return nil
end

function M.describe(s, activity)
    if not activity then return nil end
    local player=s and s.game and s.game.player
    return {task_id=activity.task_id,kind=M.label(activity.kind),
        status=activity.stop_error and 'error' or (M.live(activity,player) and 'running' or 'ended'),
        turns_executed=activity.turns_executed or 0,
        native_max_turns=activity.max_turns,
        automation_max_turns=activity.max_turns,
        stop_reason=activity.stop_reason,native_message=activity.native_message}
end

-- Drop a finished auto-combat activity so `nativePhase` and observe stop
-- reporting it as current. Command activities are finalized by `finish`.
function M.reap(s)
    local activity=s and s.native_activity
    if not activity or activity.owner~='auto_combat' then return end
    local player=s.game and s.game.player
    if M.live(activity,player) then return end
    activity.status='stopped'
    s.native_activity=nil
end

return M
