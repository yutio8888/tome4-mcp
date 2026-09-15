-- GPL-3.0-or-later. Track native rest lifetimes, including their final callbacks.
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local Interactions=require 'mod.mcp_bridge.Interactions'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local M={MAX_TURNS=1000}
local starting={}
local tasks=setmetatable({}, {__mode='k'})
local listener
local function changed(root) if listener then listener(root) end end
local function pack(...) return {n=select('#',...),...} end

function M.reset(callback)
    starting={};tasks=setmetatable({}, {__mode='k'});listener=callback
end
function M.current(root)
    for _,task in ipairs(root and root.tasks or {}) do if not task.done then return task end end
end
function M.forPlayer(player)
    local task=player.resting and tasks[player.resting]
    if task then return task end
    local current=Tracker.current()
    task=current and starting[current]
    if task and player==task.player and player.resting then
        task.rest=player.resting;tasks[player.resting]=task
        return task
    end
end
function M.claimPopup(d)
    local owner=Tracker.current()
    local task=owner and starting[owner]
    if not task or not task.expect_popup then return end
    task.expect_popup=false;task.dialog=d
    Interactions.adoptPassiveDialog(d,owner,task)
    return true
end
function M.start(player,fn,...)
    local owner=Tracker.current()
    if not owner or not Compat.available('restInit') or not Compat.matches('playerRestStop',player.restStop) then
        return fn(player,...)
    end
    local root=owner.root
    local task={owner=owner,root=root,player=player,kind='task.rest',turns=0,expect_popup=true}
    root.tasks=root.tasks or {};root.tasks[#root.tasks+1]=task
    task.task_id=root.command.command_id..':task-'..#root.tasks
    local previous=starting[owner];starting[owner]=task
    local result=pack(pcall(fn,player,...))
    starting[owner]=previous
    task.rest=task.rest or player.resting
    if task.rest and not task.done then tasks[task.rest]=task end
    task.turns=task.rest and task.rest.cnt or 0
    root.command.native_task_turns=(root.command.native_task_turns or 0)+task.turns
    if not result[1] then task.error=true;Tracker.error(root,result[2])
    elseif not task.rest then task.done=true end
    changed(root)
    if not result[1] then error(result[2],0) end
    return unpack(result,2,result.n)
end
function M.finish(player,fn,...)
    local task=M.forPlayer(player)
    if not task then return fn(player,...) end
    local result=pack(pcall(Tracker.scope,task.owner,fn,player,...))
    task.turns=task.rest and task.rest.cnt or task.turns
    task.message=Details.text(select(1,...),512)
    task.done=true
    if task.rest then tasks[task.rest]=nil end
    if not result[1] then task.error=true;Tracker.error(task.root,result[2]) end
    changed(task.root)
    if not result[1] then error(result[2],0) end
    return unpack(result,2,result.n)
end
function M.stop(root,reason)
    local task=M.current(root)
    if not task or task.stopping or task.error then return end
    if task.player.resting and task.player.resting==task.rest then
        task.stopping=true;task.stop_reason=task.stop_reason or reason
        local ok,err=pcall(task.player.restStop,task.player,reason)
        task.stopping=false
        if not ok then task.error=true;Tracker.error(root,err) end
    end
end
function M.afterStep(task,energy_before)
    if not task then return end
    local command=task.root.command
    local turns=task.rest and task.rest.cnt or task.turns
    command.native_task_turns=(command.native_task_turns or 0)+math.max(0,turns-task.turns)
    task.turns=turns
    local energy=task.player.energy and task.player.energy.value
    if not Details.finite(energy_before) or not Details.finite(energy) then
        command.energy_spent_complete=false;Tracker.error(task.root,'Native task left invalid energy')
    end
    changed(task.root)
end
function M.describe(root)
    local task=M.current(root)
    if not task then task=root and root.tasks and root.tasks[#root.tasks] end
    if not task then return nil end
    return {task_id=task.task_id,kind=task.kind,status=task.done and 'ended' or 'running',
        turns_executed=task.rest and task.rest.cnt or task.turns,
        native_max_turns=task.rest and Details.number(task.rest.rest_turns),
        automation_max_turns=M.MAX_TURNS,stop_reason=task.stop_reason,native_message=task.message}
end
function M.release(root)
    for _,task in ipairs(root.tasks or {}) do if task.rest then tasks[task.rest]=nil end end
    root.tasks=nil
end
return M
