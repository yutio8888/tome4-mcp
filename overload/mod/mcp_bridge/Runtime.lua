-- GPL-3.0-or-later. Everything here is module-local and never saved in a game.
local Json=require 'mod.mcp_bridge.Json'
local Transport=require 'mod.mcp_bridge.TransportSocket'
local Observer=require 'mod.mcp_bridge.Observer'
local Actions=require 'mod.mcp_bridge.Actions'
local Input=require 'mod.mcp_bridge.Input'
local Journal=require 'mod.mcp_bridge.Journal'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local Interactions=require 'mod.mcp_bridge.Interactions'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local NativeTasks=require 'mod.mcp_bridge.NativeTasks'
local CommandLedger=require 'mod.mcp_bridge.CommandLedger'
local ObservationViews=require 'mod.mcp_bridge.ObservationViews'
local ObservationCollections=require 'mod.mcp_bridge.ObservationCollections'
local M={MAX_RETAINED_COMMANDS=256,COMMAND_RECEIPT_BYTES=4194304,MAX_RECENT_SNAPSHOTS=16,SNAPSHOT_BYTE_BUDGET=4194304}
local state, serial
serial=0
local function now()
    return core and core.game and core.game.getTime and core.game.getTime() or os.time()*1000
end
local function identifier(prefix)
    serial=serial+1
    -- Do not call util.uuid: it consumes the gameplay RNG.
    return prefix..'-'..os.time()..'-'..tostring(now())..'-'..serial..'-'..tostring({}):gsub('[^%w]','')
end
local function integer(v,low,high) return type(v)=='number' and v%1==0 and v>=low and v<=high end
local function stringId(v) return type(v)=='string' and #v>0 and #v<=256 and not v:find('%z') end
local function bump(s) s.revision=s.revision+1 end
local function invocation(s) return s.execution or s.active and s.active.invocation end
local function busy(g,s)
    if g.target_co or g.target and g.target.active then return true end
    for _,dialog in ipairs(g.dialogs or {}) do
        if not s or not s.active or dialog~=s.active.rest_dialog then return true end
    end
    return false
end
local function companion()
    local controller=package.loaded['mod.battle_companion.Controller']
    if type(controller)=='table' and type(controller.isRunning)=='function' then return controller end
end
local function localCombat(s)
    local controller=companion()
    return controller and controller.isRunning(s.game.player) or false
end
local function nativePhase(s)
    local g,p=s.game,s.game.player
    if s.native_error then return 'unavailable' end
    if not p or not g.level or not g.level.map or p.x==nil or p.y==nil or g.creating_player then return 'unavailable' end
    if p.dead or type(p.life)=='number' and p.life<=(p.die_at or 0) then return 'terminal' end
    local root=invocation(s)
    if root then
        if (root.player~=p or root.level~=g.level) and (not root.done or NativeTasks.current(root)) then return 'needs_input' end
        if not Interactions.ownsAll(g,root) then return 'needs_input' end
        if Interactions.current(root) then
            return root.command.input_owner=='manual' and 'needs_input' or 'awaiting_input'
        end
        if NativeTasks.current(root) then return 'running_native_task' end
        if Interactions.hasAutoDialog(root) then
            return g.onTickEndExists and g:onTickEndExists() and 'settling' or 'needs_input'
        end
        if not root.done then return 'needs_input' end
    end
    if busy(g,s) then return 'needs_input' end
    if s.saving or savefile_pipe and (savefile_pipe.saving
        or type(savefile_pipe.pipe)=='table' and #savefile_pipe.pipe>0
        or type(savefile_pipe.waiton)=='table' and next(savefile_pipe.waiton)~=nil)
        or s.changing then return 'settling' end
    if localCombat(s) then return 'unavailable' end
    if p.resting and s.active and p.resting==s.active.native_rest then return 'settling' end
    if p~=s.player or g.level~=s.level or not p.player or p.resting or p.running
        or g.wasd_state and (g.wasd_state.cnt or 0)>0 then return 'unavailable' end
    if not g.paused or not p.energy or p.energy.value<(g.energy_to_act or 1000) then return 'settling' end
    if g.onTickEndExists and g:onTickEndExists() then return 'settling' end
    return 'ready'
end
local function meta(s)
    local controller=companion()
    local raw=controller and type(controller.observation)=='function' and controller.observation(s.game.player)
    local summary=type(raw)=='table' and {state=Details.text(raw.state,48),code=Details.text(raw.code,128),
        message=Details.text(raw.message,512),actions=Details.number(raw.actions)} or nil
    local phase=nativePhase(s)
    return {session_id=s.session_id,level_instance_id=s.level_id,revision=s.revision,protocol_version=4,
        history=s.ledger and s.ledger:history() or Json.null,
        phase=phase,actionable=(phase=='ready' and s.control_token~=nil) or false,
        control_lease=s.control_token and 'held' or 'released',
        needs_reconnect=(s.access_mode=='control' and not s.control_token) and true or nil,
        control_source=s.control_token and 'remote' or localCombat(s) and 'battle_companion' or 'manual',
        battle_companion=summary}
end
local function snapshot(s,radius,options)
    local result=Observer.capture(s.game,meta(s),radius,options)
    result.history=s.ledger:history()
    result.collection_refs=ObservationCollections.refs()
    result.events=Journal.capture(s.game,options and options.events_after)
    local root=invocation(s)
    if root then
        local command=root.command
        result.pending_command={command_id=command.command_id,status=command.status,
            input_owner=command.input_owner,execution_released=false,
            interaction=Interactions.describe(root,meta(s)),native_task=NativeTasks.describe(root)}
    end
    return result
end
local function commandView(command,include_map,response_id,options_offset)
    local out={}
    for _,key in ipairs{'command_id','seq','status','code','energy_spent','native_return','world_tick_before',
        'world_tick_after','revision_before','revision_after','snapshot','snapshot_availability','interruption','uncertain',
        'turns_executed','max_turns','stop_reason','native_message','level_changed','target_geometry',
        'points_spent','points_returned','point_pool','previous_value','new_value'} do out[key]=command[key] end
    if command.protocol then
        out.revision=state.revision;out.input_owner=command.input_owner
        out.accepted=true;out.seq=command.seq
        out.history=state.ledger:history()
        out.snapshot_availability=command.snapshot_availability or (command.snapshot and 'retained' or 'not_captured')
        out.execution_released=command.execution_released==true
        out.energy_spent_complete=command.energy_spent_complete~=false
        if command.invocation then out.interaction=Interactions.describe(command.invocation,meta(state),options_offset) end
        out.native_task=command.native_task or command.invocation and NativeTasks.describe(command.invocation)
        local receipt=command.responses and command.responses[response_id or command.last_response_id]
        if receipt then out.response_receipt={response_id=receipt.response_id,interaction_id=receipt.interaction_id,
            state=receipt.state,code=receipt.code} end
    end
    if command.native_rest then out.turns_executed=command.native_rest.cnt or 0 end
    -- A pending interaction can change life/actors; return a live snapshot so
    -- the caller does not mistake the pre-action snapshot for the current state.
    if command.protocol and command.status=='awaiting_input' and not out.snapshot and state then
        out.snapshot=snapshot(state)
        out.snapshot_scope='live'
    end
    if include_map==false and out.snapshot then
        local compact={};for k,v in pairs(out.snapshot) do if k~='map' then compact[k]=v end end
        compact.map=Json.null;out.snapshot=compact
    end
    return out
end
local function receiptBytes(command)
    local size=#(command.command_id or '')+#tostring(command.fingerprint or '')+64
    if type(command.responses)=='table' then
        for id,receipt in pairs(command.responses) do
            size=size+#tostring(id)+#tostring(receipt.fingerprint or '')
        end
    end
    return size
end
-- Snapshots have their own 16-entry / 4 MiB budget (LED-06), independent of
-- the 256-receipt ledger. Evicting a snapshot keeps the receipt queryable.
local function retainSnapshot(s,command)
    local ok,encoded=pcall(Json.encode,command.snapshot)
    command.snapshot_bytes=(ok and type(encoded)=='string') and #encoded or 0
    s.snapshots[#s.snapshots+1]={seq=command.seq,bytes=command.snapshot_bytes}
    s.snapshot_bytes=s.snapshot_bytes+command.snapshot_bytes
    while #s.snapshots>M.MAX_RECENT_SNAPSHOTS or s.snapshot_bytes>M.SNAPSHOT_BYTE_BUDGET do
        local oldest=table.remove(s.snapshots,1)
        if not oldest then break end
        s.snapshot_bytes=s.snapshot_bytes-oldest.bytes
        local evicted=s.ledger:get(oldest.seq)
        if evicted then
            evicted.snapshot=nil;evicted.snapshot_bytes=nil;evicted.snapshot_availability='evicted'
        end
    end
end
local function finish(s,command,status,code)
    command.status,command.code=status,code or command.code
    command.world_tick_after=s.game.turn or 0
    command.revision_after=s.revision
    if s.active==command then s.active=nil end
    local root=command.invocation
    if not root or root.done and not NativeTasks.current(root) and status~='needs_input' and not root.error then
        command.execution_released=true
        if root then
            command.native_task=NativeTasks.describe(root)
            NativeTasks.release(root);Interactions.release(root);Tracker.release(root)
            if s.execution==root then s.execution=nil end
            command.invocation=nil
        end
    end
    -- Retain deduplication metadata without retaining an entire old level.
    command.player,command.level,command.control_token=nil,nil,nil
    command.native_rest,command.rest_dialog=nil,nil
    command.snapshot=snapshot(s)
    command.snapshot_availability=command.snapshot and 'retained' or 'not_captured'
    if command.snapshot then retainSnapshot(s,command) end
    if command.seq and s.ledger then
        s.ledger:touch(command.seq,receiptBytes(command))
        if command.execution_released then s.ledger:release(command.seq) end
    end
end
local function restFault(s,command)
    command.stop_error=true;command.uncertain=true
    s.native_error=s.native_error or 'native_rest_stop_error'
    s.failed_rest=s.game.player and s.game.player.resting
    if s.control_token then s.control_token=nil;bump(s) end
end
local function stopRest(s,command,reason)
    if not command or command.action.type~='rest' or command.stopping or command.stop_error then return end
    command.stop_reason=command.stop_reason or reason
    local p=s.game.player
    if p and p.resting and p.resting==command.native_rest then
        command.turns_executed=p.resting.cnt or 0
        command.stopping=true
        local ok,err=pcall(p.restStop,p,reason)
        command.stopping=false
        if not ok then restFault(s,command) end
    end
end
local function revoke(s,reason,resumable_scene)
    local changed=s.control_token~=nil
    s.control_token=nil
    local active=s.active
    if active and active.status=='queued' then
        bump(s);finish(s,active,'cancelled',reason)
    elseif active then
        active.interruption=reason;stopRest(s,active,reason)
        local root=active.invocation
        if root then
            if active.pending_response then
                local receipt=active.pending_response
                receipt.state,receipt.code='rejected',reason
                active.pending_response=nil
                Interactions.reissue(receipt.handle)
                receipt.handle,receipt.answer,receipt.control_token=nil,nil,nil
            end
            if reason=='disconnected' or reason=='control_replaced' or resumable_scene then
                if active.input_owner~='manual' then active.input_owner='orphaned' end
            else active.input_owner='manual';active.handoff_requested=reason end
            if NativeTasks.current(root) and not active.pending_task_stop then
                active.pending_task_stop=true
                s.game:onTickEnd(function()
                    if state~=s or not active.invocation then return end
                    active.pending_task_stop=false
                    if root.player==s.game.player and root.level==s.game.level then NativeTasks.stop(root,reason) end
                    bump(s)
                end,'mcp_bridge_task_stop')
            end
        end
        if active.stop_error and active.status~='executing' then finish(s,active,'failed','native_rest_stop_error') end
    end
    if changed then bump(s) end
end
local function sync(s)
    if s.player~=s.game.player or s.level~=s.game.level then
        local root=invocation(s)
        local owned=root and root.player==s.game.player and
            (s.scene_resume==root and root.level==s.game.level
                or s.scene_transition and s.scene_transition.root==root and root.transitioning)
        revoke(s,'scene_changed',owned)
        s.scene_resume=nil
        s.player,s.level=s.game.player,s.game.level
        s.level_serial=s.level_serial+1;s.level_id='level-'..s.level_serial
        if s.views then s.views:invalidateContext{session_id=s.session_id,level_instance_id=s.level_id} end
        bump(s)
    end
end
function M.reset(g)
    local previous=state
    state=nil
    if previous and previous.transport then previous.transport:close() end
    Observer.reset()
    Journal.reset()
    state={game=g,player=g.player,level=g.level,session_id=identifier('tome'),revision=1,
        level_serial=1,level_id='level-1',ready_serial=0,
        tick_serial=0,tick_depth=0,next_start=0}
    local s=state
    s.snapshots={};s.snapshot_bytes=0
    s.connection_generation=1
    s.views=ObservationViews.new{}
    s.ledger=CommandLedger.new{max_retained=M.MAX_RETAINED_COMMANDS,byte_budget=M.COMMAND_RECEIPT_BYTES,
        on_evict=function(record)
            if record.snapshot then
                for index=#s.snapshots,1,-1 do
                    if s.snapshots[index].seq==record.seq then
                        s.snapshot_bytes=s.snapshot_bytes-s.snapshots[index].bytes
                        table.remove(s.snapshots,index);break
                    end
                end
            end
            record.snapshot=nil;record.snapshot_bytes=nil;record.native_rest=nil;record.rest_dialog=nil
            record.player,record.level,record.control_token=nil,nil,nil
            record.snapshot_availability='evicted'
        end}
    local function changed(root)
        if state==s and root.game==g then s.execution=root;bump(s) end
    end
    Tracker.reset(changed);Interactions.reset(changed);NativeTasks.reset(changed)
    Input.attach(g)
end
local function ensure(g)
    if not state or state.game~=g then M.reset(g) end
    return state
end
function M.hasControl(player)
    return state and state.game.player==player and (state.control_token~=nil or state.active~=nil or state.execution~=nil) or false
end
function M.holdsNativeInput(g)
    local s=state
    if not s or s.game~=g then return false end
    local root=invocation(s)
    return root and (root.error~=nil
        or (root.player~=g.player or root.level~=g.level) and (not root.done or NativeTasks.current(root))
        or Interactions.current(root)~=nil
        or not Interactions.ownsAll(g,root) or not root.done and not NativeTasks.current(root)) or false
end
function M.recordEnergy(player,before,after)
    local owner=Tracker.current()
    local task=NativeTasks.forPlayer(player)
    local root=owner and owner.root or task and task.root
    if not root or player~=root.player then return end
    local command=root.command
    if Details.finite(before) and Details.finite(after) then
        command.energy_spent=(command.energy_spent or 0)+math.max(0,before-after)
        command.energy_measured=true
    else command.energy_spent_complete=false;Tracker.error(root,'Native useEnergy left invalid energy') end
end
function M.manualInput(g,reason)
    if not state or state.game~=g then return end
    local s=state
    bump(s)
    revoke(s,'manual_'..reason)
    s.authenticated=false
    if s.transport then s.transport:disconnectClient('manual_input') end
end
function M.onReady(player)
    local s=state
    if s and s.game.player==player and s.game.paused and player.energy
        and player.energy.value>=(s.game.energy_to_act or 1000) then s.ready_serial=s.ready_serial+1 end
end
function M.beforeRestStep(player)
    local s=state
    local task=NativeTasks.forPlayer(player)
    if task and s then
        if task.root.error or task.root.player~=s.game.player or task.root.level~=s.game.level then return false end
        local command=task.root.command
        if not s.control_token or command.input_owner~='remote' then
            NativeTasks.stop(task.root,'control_lost');return false
        end
        if (command.native_task_turns or 0)>=NativeTasks.MAX_TURNS then
            NativeTasks.stop(task.root,'task_budget_exhausted');return false
        end
        return true,task
    end
    -- A failed native cleanup may retain rest state/effects. Quarantine its
    -- automatic steps without pretending to have repaired native state.
    if s and s.game.player==player and s.failed_rest and player.resting==s.failed_rest then return false end
    local command=s and s.active
    if not command or command.action.type~='rest' or player~=s.game.player
        or not player.resting or player.resting~=command.native_rest then return true end
    command.turns_executed=player.resting.cnt or 0
    if not s.control_token then stopRest(s,command,'control_lost');return false end
    if command.turns_executed>=command.max_turns then
        stopRest(s,command,'max_turns');return false
    end
    return true
end
function M.afterRestStep(player,energy_before,task)
    if task then NativeTasks.afterStep(task,energy_before);return end
    local s=state;local command=s and s.active
    if command and command.action.type=='rest' and player==s.game.player and command.native_rest then
        command.turns_executed=command.native_rest.cnt or 0
        command.energy_spent=(command.energy_spent or 0)+math.max(0,energy_before-player.energy.value)
    end
end
function M.markRestInterruption(player,reason)
    local s=state;local command=s and s.active
    if command and command.action.type=='rest' and player==s.game.player
        and player.resting and player.resting==command.native_rest then command.stop_reason=reason end
end
function M.onRestStop(player,message)
    local s=state;local command=s and s.active
    if not command or command.action.type~='rest' or player~=s.game.player or not player.resting then return end
    if player.resting~=command.native_rest then
        if not s.starting_rest or player.resting.dialog~=command.rest_dialog then return end
        command.native_rest=player.resting
    end
    command.turns_executed=player.resting.cnt or 0
    command.native_message=Details.text(message,512)
    command.stop_reason=command.stop_reason or (player.resting.rested_fully and 'native_complete' or 'native_stopped')
    local was_stopping=command.stopping
    command.stopping=true
    return command,was_stopping
end
function M.afterRestStop(command,was_stopping)
    if command then command.stopping=was_stopping end
end
function M.onRestStopError(command)
    if state and command and state.active==command then restFault(state,command) end
end
function M.beforeTick(g)
    local s=ensure(g);s.tick_depth=s.tick_depth+1
end
-- A native UI can be produced by an NPC while settling the one MCP action.
-- Only that active native tick can supply missing ownership; observer calls,
-- idle frames, pre-existing dialogs and manual handoffs cannot adopt a dialog.
function M.nativeUIOwner(g)
    local s=state
    if not s or s.game~=g or s.tick_depth<=0 or s.native_error then return end
    local command=s.active
    local root=command and command.invocation
    if not root or root.error or command.input_owner=='manual'
        or command.handoff_requested or root.player~=g.player then return end
    if root.level~=g.level and not root.transitioning then return end
    if command.status=='executing' or command.status=='settling' or command.status=='running_native_task' then return root end
end

function M.beginSceneChange(g)
    local s=state
    local owner=Tracker.current()
    local root=owner and owner.root
    local owned=s and s.game==g and root and s.active==root.command
        and root.command.action.type=='change_level' and root.command.status=='executing'
        and root.command.input_owner~='manual' and not root.command.handoff_requested
        and root.player==g.player and not root.error and not NativeTasks.current(root)
        and Compat.matches('changeLevelReal',g.changeLevelReal)
    if not owned then M.boundary(g,'scene_changed',true);return end
    local ticket={state=s,root=root,parent=s.scene_transition}
    s.scene_transition=ticket;s.changing=true;root.transitioning=true
    revoke(s,'scene_changed',true);bump(s)
    return ticket
end
function M.endSceneChange(g,ticket,ok)
    if not ticket or state~=ticket.state then M.boundary(g,'scene_changed',false);return end
    local s,root=ticket.state,ticket.root
    s.scene_transition=ticket.parent
    if not ticket.parent then
        root.transitioning=nil;s.changing=false
        if ok and s.active==root.command and root.player==g.player and not root.error then
            root.level=g.level;s.scene_resume=root
        end
        sync(s)
    end
    bump(s)
end
function M.afterTick(g)
    local s=ensure(g);s.tick_depth=math.max(0,s.tick_depth-1)
    if s.tick_depth==0 then s.tick_serial=s.tick_serial+1;bump(s);sync(s) end
end
function M.onNativeError(g,reason,is_tick)
    local s=ensure(g)
    if is_tick then s.tick_depth=math.max(0,s.tick_depth-1) end
    if s.native_error then
        if s.active and s.active.stop_error then finish(s,s.active,'failed','native_rest_stop_error') end
        return
    end
    -- A failed native tick is not a completed action boundary. Keep the
    -- transport readable, but quarantine writes until a fresh game session.
    s.native_error=reason or 'native_error'
    bump(s);revoke(s,s.native_error)
    local command=s.active
    if command then
        command.uncertain=true
        finish(s,command,'failed',s.native_error)
    end
end
function M.deferSave(g)
    local s=state
    if not s or s.game~=g or s.allow_owned_save or not invocation(s) then return false end
    if not s.deferred_save and g.log then g.log('MCP: save deferred until the current native action finishes.') end
    s.deferred_save=true
    -- Autosave also arrives from the savefile coroutine after leaving a zone.
    -- Defer it without answering or handing off the pending native dialog.
    -- A physical save shortcut already revokes control through InputGuard.
    return true
end
local function queueDeferredSave(s)
    if not s.deferred_save then return false end
    s.deferred_save=false
    s.game:onTickEnd(function()
        if state~=s then return end
        s.allow_owned_save=true
        local ok,err=pcall(s.game.saveGame,s.game)
        s.allow_owned_save=false
        if not ok then M.onNativeError(s.game,'native_save_error',false)
        else
            -- Native coroutine dispatch precedes onTickEnd. A save registered
            -- here has not started yet; force the next native tick so a paused
            -- game starts its savefile coroutine and drains background writes.
            s.game:onTickEnd(function() end,'mcp_bridge_save_start')
        end
    end,'mcp_bridge_deferred_save')
    bump(s)
    return true
end
function M.boundary(g,reason,enter,detail)
    if not state or state.game~=g then return end
    local s=state
    bump(s)
    if reason=='saving' then s.saving=enter
    elseif reason=='scene_changed' then s.changing=enter end
    if reason=='dialog' then
        Input.attach(g)
        local root=Interactions.dialogOwner(detail)
        if root and root==invocation(s) then
            if not enter then Interactions.closeDialog(detail) end
            Interactions.exposeTop(root)
            return
        end
        -- An unowned closeable popup raised while an owned remote action is
        -- settling is adopted as a dialog.notice so the agent can answer it
        -- instead of being forced into manual control (round-5 report 3.8).
        local active=invocation(s)
        if enter and active and s.active==active.command and active.command.input_owner=='remote'
            and not active.command.handoff_requested then
            if Interactions.adoptNotice(detail,active) then
                Interactions.exposeTop(active)
                return
            end
        end
        local command=s.active
        if command and command.action.type=='rest' then
            -- Native restInit always creates its own popup before onRestStart.
            -- Only that one dialog belongs to this command; other UI revokes.
            if enter and s.starting_rest and not command.rest_dialog then command.rest_dialog=detail;return end
            if detail and detail==command.rest_dialog then return end
        end
    end
    if (enter~=false or reason=='dialog') and not (reason=='saving' and s.allow_owned_save) then revoke(s,reason) end
end
local function settle(s)
    local command=s.active
    local root=invocation(s)
    if root and root.error then
        local code=root.command.action.type=='use_item' and 'native_item_error'
            or root.result_from_talent and 'native_talent_error' or 'native_action_error'
        s.native_error=code
        local owned=root.command
        owned.uncertain=true;owned.native_message=Details.text(root.error,512)
        revoke(s,code)
        if s.active==owned then finish(s,owned,'failed',code) end
        return
    end
    if root and not command and root.done and nativePhase(s)=='ready' and s.tick_depth==0 then
        if queueDeferredSave(s) then return end
        local owned=root.command
        owned.execution_released=true
        owned.native_task=NativeTasks.describe(root)
        NativeTasks.release(root);Interactions.release(root);Tracker.release(root);owned.invocation=nil;s.execution=nil
        bump(s)
    end
    if not command or command.status=='queued' or command.status=='executing' then return end
    if command.stop_error then finish(s,command,'failed','native_rest_stop_error');return end
    if s.tick_depth>0 or s.tick_serial<=command.tick_before then return end
    local phase=nativePhase(s)
    if command.invocation then
        local root=command.invocation
        if phase=='awaiting_input' then
            if command.handoff_requested then
                command.input_owner='manual'
                finish(s,command,'needs_input',command.handoff_requested)
            elseif not command.pending_response then command.status='awaiting_input';command.code='awaiting_native_input' end
            return
        end
        if phase=='running_native_task' then command.status='running_native_task';command.code='native_task_running';return end
        if root.done and root.result_from_talent then
            command.action_ok=root.native_return
            command.native_return=root.native_return
            command.code=root.native_return and 'action_complete' or 'native_rejected'
        elseif root.done then
            command.code=command.action_code
        end
    end
    if phase=='needs_input' then
        local reason=command.handoff_requested or 'unsupported_interaction'
        revoke(s,reason);finish(s,command,'needs_input',reason)
    elseif phase=='terminal' then
        revoke(s,'terminal');finish(s,command,'failed','terminal')
    elseif s.level~=command.level or s.player~=command.player then
        revoke(s,'scene_changed')
        if command.action.type=='change_level' and s.player==command.player then
            command.level_changed=true
            if phase=='ready' then
                if queueDeferredSave(s) then return end
                finish(s,command,'completed','level_changed')
            end
        else finish(s,command,'failed','scene_changed') end
    elseif phase=='ready' and (not command.requires_ready or s.ready_serial>command.ready_before) then
        if queueDeferredSave(s) then return end
        if command.action.type=='rest' then
            finish(s,command,command.interruption and 'cancelled' or command.action_ok and 'completed' or 'failed',
                command.stop_reason or command.code)
        else finish(s,command,command.action_ok and 'completed' or 'failed',command.code) end
    end
end
local function execute(s,command)
    if state~=s or s.active~=command or command.status~='queued' then return end
    sync(s)
    if s.active~=command then return end
    local failure
    if command.control_token~=s.control_token then failure='control_lost'
    elseif command.expected_revision~=s.revision then failure='stale_revision'
    elseif nativePhase(s)~='ready' then failure='not_ready' end
    if failure then bump(s);finish(s,command,'cancelled',failure);return end
    command.status='executing'
    command.tick_before=s.tick_serial;command.ready_before=s.ready_serial
    command.world_tick_before=s.game.turn or 0;command.revision_before=s.revision
    command.player,command.level=s.player,s.level
    local target=command.action.target_id and Observer.resolve(s.game,meta(s),command.action.target_id)
    local result
    if command.action.type=='rest' then
        command.max_turns=command.action.max_turns;command.turns_executed=0
        local p=s.game.player
        local info=type(p.restInit)=='function' and debug.getinfo(p.restInit,'S')
        if not Compat.matches('restInit',p.restInit)
            and (not info or type(info.source)~='string' or not info.source:match('[/]engine/interface/PlayerRest%.lua$')) then
            result={ok=false,code='rest_modified',energy_spent=0}
        else
            local energy=p.energy.value
            s.starting_rest=true
            local ok,err=pcall(p.restInit,p)
            s.starting_rest=false
            command.native_rest=p.resting or command.native_rest
            if command.native_rest then command.turns_executed=command.native_rest.cnt or 0 end
            result={ok=ok,code=ok and 'rest_complete' or 'execution_error',energy_spent=math.max(0,energy-p.energy.value)}
            if not ok then
                command.uncertain=true
                stopRest(s,command,'execution_error')
            elseif command.interruption then stopRest(s,command,command.interruption) end
        end
    else
        local root
        Journal.update(s.game)
        local journal_cursor=Journal.capture(s.game).head_cursor
        root,result=Tracker.startAction(s.game,command,function()
            return Actions.execute(s.game,command.action,target,meta(s),command)
        end)
        -- A native rejection writes its reason to the player log. Surface the
        -- new lines so the agent does not have to scan the event delta (3.c).
        if result and result.code=='native_rejected' and not result.native_message then
            local page=Journal.capture(s.game,journal_cursor)
            local parts={}
            for _,entry in ipairs(page.entries or {}) do
                if entry.op=='append' and type(entry.text)=='string' and entry.text~='' then
                    parts[#parts+1]=entry.text
                    if #parts>=3 then break end
                end
            end
            if #parts>0 then result.native_message=table.concat(parts,' | ') end
        end
    end
    if not command.energy_measured then command.energy_spent=result.energy_spent or 0 end
    command.native_return=result.native_return;command.action_ok=result.ok;command.code=result.code
    command.action_code=result.code
    command.level_changed=result.level_changed
    command.native_message=Details.text(result.native_message,512) or command.native_message
    command.points_spent=Details.number(result.points_spent)
    command.points_returned=Details.number(result.points_returned)
    command.point_pool=Details.text(result.point_pool,32)
    command.previous_value=Details.number(result.previous_value)
    -- Preserve false explicitly: it describes a previously locked category.
    if result.previous_value==false then command.previous_value=false end
    command.new_value=Details.number(result.new_value)
    if result.uncertain then
        -- Growth and inventory callbacks may fail after a partial mutation.
        -- Preserve the command once, keep observation available, and require a
        -- fresh loaded session before issuing more native changes.
        command.uncertain=true
        s.native_error=result.code or 'native_action_error'
        revoke(s,s.native_error)
        finish(s,command,'failed',s.native_error)
        return
    end
    if command.stop_error then finish(s,command,'failed','native_rest_stop_error');return end
    command.requires_ready=not s.game.paused or s.player.energy.value<(s.game.energy_to_act or 1000)
    command.status='settling'
    bump(s)
end
local function executeResponse(s,command,receipt)
    if state~=s or s.active~=command or command.pending_response~=receipt or receipt.state~='queued' then return end
    sync(s)
    local failure
    if command.pending_response~=receipt then return end
    if receipt.control_token~=s.control_token or command.input_owner~='remote' then failure='control_lost'
    elseif nativePhase(s)~='awaiting_input' then failure='not_ready'
    elseif receipt.queued_revision~=s.revision then failure='stale_revision'
    elseif Interactions.current(command.invocation)~=receipt.handle then failure='interaction_expired' end
    local prepared
    if not failure then prepared,failure=Interactions.prepare(receipt.handle,receipt.answer,meta(s)) end
    command.pending_response=nil
    if failure then
        receipt.state,receipt.code='rejected',failure
        Interactions.reissue(receipt.handle);bump(s)
        receipt.handle,receipt.answer,receipt.control_token=nil,nil,nil
        return
    end
    command.status='executing'
    command.tick_before=s.tick_serial;command.ready_before=s.ready_serial
    local p=s.game.player
    local before=p.energy and p.energy.value
    local measured_before=command.energy_spent or 0
    local ok,err=pcall(Interactions.apply,receipt.handle,prepared)
    receipt.state='applied';receipt.handle=nil;receipt.answer=nil;receipt.control_token=nil
    if Details.finite(before) and p.energy and Details.finite(p.energy.value) then
        local observed=math.max(0,before-p.energy.value)
        local measured=(command.energy_spent or 0)-measured_before
        if observed>measured then
            command.energy_spent=(command.energy_spent or 0)+observed-measured
            command.energy_spent_complete=false
        end
    else ok=false;err='Native talent left invalid energy';command.energy_spent_complete=false end
    if not ok then
        Tracker.error(command.invocation,err)
        command.uncertain=true;command.native_message=Details.text(err,512)
    end
    command.requires_ready=not s.game.paused or not p.energy or not Details.finite(p.energy.value)
        or p.energy.value<(s.game.energy_to_act or 1000)
    command.status='settling'
    bump(s)
end
local function fail(code,message,details)
    local error={code=code,message=message or code:gsub('_',' ')}
    if details then for key,value in pairs(details) do error[key]=value end end
    return nil,error
end
local function dispatch(s,request)
    if type(request.v)~='number' or not stringId(request.id) or type(request.op)~='string'
        or type(request.args)~='table' or request.args==Json.null then return fail('invalid_request') end
    if request.v~=4 then return fail('protocol_mismatch') end
    local a,op=request.args,request.op
    if op=='connect' or op=='connect_observer' then
        if type(a.token)~='string' or a.token~=s.token then return fail('authentication_failed') end
        s.authenticated=true
        if s.transport and s.transport.markAuthenticated then s.transport:markAuthenticated() end
        sync(s)
        -- Re-acquiring control invalidates every old lease, including queued
        -- commands. No automatic client reconnect is implemented in Runtime.
        revoke(s,'control_replaced')
        s.protocol=4
        s.connection_generation=(s.connection_generation or 1)+1
        s.views:invalidateContext{connection_generation=s.connection_generation}
        s.access_mode=op=='connect_observer' and 'observe' or 'control'
        if s.access_mode=='control' then
            local controller=companion()
            if controller and controller.isRunning(s.game.player) then
                if type(controller.remoteTakeover)=='function' then controller.remoteTakeover(s.game.player)
                else controller.stop(s.game.player,'remote_control') end
            end
            s.control_token=identifier('control');bump(s)
            local root=invocation(s)
            if root and s.active==root.command and root.command.input_owner=='orphaned'
                and root.player==s.game.player and root.level==s.game.level then
                root.command.input_owner='remote';root.command.control_token=s.control_token
            end
        elseif invocation(s) then
            local command=invocation(s).command
            command.input_owner='manual';command.handoff_requested='observe_mode'
        end
        local snap=snapshot(s)
        local result={session_id=s.session_id,control_token=s.control_token or Json.null,revision=s.revision,mode=s.access_mode,
            protocol_version=4,history=s.ledger:history(),
            capabilities={protocol=4,actions=Json.array{'move','wait','attack','use_talent','set_sustain','use_item','change_level','rest',
                    'spend_stat','learn_talent','learn_category','unlearn_talent','pickup','equip','unequip'},
                connection_modes=Json.array{'control','observe'},
                talents=Actions.capabilities(s.game.player),
                talent_execution='native_interactive',
                interactions=Json.array{'target.grid','target.direction','dialog.confirm','dialog.choice','dialog.notice','inventory.select'},
                native_tasks=Json.array{'task.rest'},
                multi_step=true,unknown_interaction='manual_handoff',
                limits={responses_per_command=Interactions.MAX_RESPONSES,options_per_page=Interactions.PAGE_SIZE},
                talent_query=true,talent_prefill=Json.array{'actor','position'},
                observation='player',max_radius=12,max_retained_commands=M.MAX_RETAINED_COMMANDS,max_rest_turns=1000,
                action_support={
                    move={implementation='supported',scope='native_movement'},
                    wait={implementation='supported',scope='native_wait'},
                    attack={implementation='supported',scope='native_attack'},
                    use_talent={implementation='supported',scope='admitted_native_entrypoints',interaction_coverage='runtime_checked'},
                    set_sustain={implementation='supported',scope='admitted_native_entrypoints'},
                    use_item={implementation='supported',scope='owned_item_native_use'},
                    change_level={implementation='supported',scope='native_exit_command'},
                    rest={implementation='supported',scope='native_rest'},
                    spend_stat={implementation='supported',scope='native_levelup'},
                    learn_talent={implementation='supported',scope='visible_known_categories',requirements='native_checked',detail_collection='progression_categories'},
                    learn_category={implementation='supported',scope='visible_known_or_lockable_categories',requirements='native_checked',detail_collection='progression_categories'},
                    unlearn_talent={implementation='limited',scope='native_last_learnt_window',reason='recent_window_only'},
                    pickup={implementation='supported',scope='player_tile'},
                    equip={implementation='supported',scope='native_inventory_rules'},
                    unequip={implementation='supported',scope='native_inventory_rules'}},
                compact_responses=true,event_cursor=true,inventory_read=true,ground_items_read=true,
                progression_read=true,inspect_kinds=Json.array{'actor','talent','progression','item','compatibility'}},snapshot=snap}
        local ok,reason=Compat.check(s.game)
        result.capabilities.native_compatibility={compatible=ok==true,reason=reason,providers='runtime_checked'}
        if not ok then result.capabilities.talents=Json.array() end
        return result
    end
    if not s.authenticated then return fail('not_connected','Call connect with the configured token.') end
    if request.v~=4 then return fail('protocol_mismatch') end
    if a.session_id~=s.session_id then return fail('session_mismatch') end
    sync(s)
    if s.access_mode=='observe' and (op=='act' or op=='stop' or op=='respond') then return fail('read_only_connection') end
    if a.include_map~=nil and type(a.include_map)~='boolean' then return fail('invalid_include_map') end
    if op=='observe' then
        if a.radius~=nil and not integer(a.radius,1,12) then return fail('invalid_radius') end
        if a.events_after~=nil and not integer(a.events_after,0,9007199254740991) then return fail('invalid_event_cursor') end
        return snapshot(s,a.radius,{include_map=a.include_map,events_after=a.events_after})
    elseif op=='inspect' then
        if not stringId(a.id) or type(a.kind)~='string' then return fail('invalid_inspect') end
        if a.target_id~=nil and not stringId(a.target_id) then return fail('invalid_inspect_target') end
        if a.x~=nil and not integer(a.x,0,2147483647) then return fail('invalid_inspect_target') end
        if a.y~=nil and not integer(a.y,0,2147483647) then return fail('invalid_inspect_target') end
        local result,code=Observer.inspect(s.game,meta(s),a.kind,a.id,a)
        if not result then return fail(code) end
        return result
    elseif op=='status' then
        if not stringId(a.command_id) then return fail('invalid_command_id') end
        local seq=CommandLedger.parseSeq(a.command_id)
        if not seq then return fail('invalid_command_id') end
        local ledger_status=s.ledger:status(seq)
        if ledger_status=='expired' then
            return fail('command_history_expired','The command was accepted earlier; its receipt is no longer retained.',
                {accepted=true,uncertain=true,recovery='do_not_replay',command_id=a.command_id})
        elseif ledger_status~='retained' then
            return fail('command_not_accepted','The command was not accepted in this session.',
                {accepted=false,uncertain=false,recovery='observe_before_resubmit',command_id=a.command_id})
        end
        local command=s.ledger:get(seq)
        if a.response_id~=nil and (not stringId(a.response_id) or not command.responses or not command.responses[a.response_id]) then
            return fail('unknown_response')
        end
        if a.options_offset~=nil and not integer(a.options_offset,0,2147483647) then return fail('invalid_options_offset') end
        return commandView(command,a.include_map,a.response_id,a.options_offset)
    elseif op=='list_collection' then
        local req=a.request
        if type(req)~='table' or req==Json.null then return fail('invalid_request') end
        s.views:setRevision(s.revision)
        s.views:invalidateContext{session_id=s.session_id,level_instance_id=s.level_id,connection_generation=s.connection_generation}
        if req.type=='next' then
            if not stringId(req.cursor) then return fail('invalid_cursor',nil,{acceptance_scope='not_applicable'}) end
            if req.collection~=nil or req.filter~=nil or req.page_size~=nil then return fail('invalid_request') end
            local page,code=s.views:nextPage(req.cursor)
            if not page then return fail(code,nil,{acceptance_scope='not_applicable'}) end
            return page
        elseif req.type=='first' then
            if not ObservationCollections.supported(req.collection) then
                return fail('unsupported_collection',nil,{acceptance_scope='not_applicable'}) end
            if req.page_size~=nil and not integer(req.page_size,1,64) then return fail('invalid_page_size') end
            local projection,code=ObservationCollections.project(s.game,meta(s),req.collection,req.filter)
            if not projection then return fail(code,nil,{acceptance_scope='not_applicable'}) end
            local page,capcode=s.views:capture{collection=req.collection,items=projection.items,
                complete=projection.complete,
                context={session_id=s.session_id,level_instance_id=s.level_id,connection_generation=s.connection_generation},
                revision=s.revision,page_size=req.page_size}
            if not page then return fail(capcode,nil,{acceptance_scope='not_applicable'}) end
            return page
        end
        return fail('invalid_request')
    elseif op=='stop' then
        if not s.control_token or a.control_token~=s.control_token then return fail('control_lost') end
        revoke(s,'stopped')
        return {stopped=true,snapshot=snapshot(s)}
    elseif op=='act' then
        if not stringId(a.command_id) or not integer(a.expected_revision,1,9007199254740991) then return fail('invalid_command') end
        local action,code=Actions.validate(a.action)
        if not action then return fail(code) end
        local fingerprint=Actions.fingerprint(action,a.expected_revision)
        -- Ledger classification precedes every lease/revision check (LED-03).
        local cls,existing=s.ledger:classify(a.command_id,fingerprint)
        if cls=='invalid' then return fail('invalid_command_id') end
        if cls=='expired' then
            return fail('command_history_expired','The command was accepted earlier; its receipt is no longer retained.',
                {accepted=true,uncertain=true,recovery='do_not_replay',command_id=a.command_id})
        elseif cls=='conflict' then
            return fail('command_conflict','This command id already has a different request.',
                {accepted=true,recovery='query_original',command_id=a.command_id})
        elseif cls=='replay' then
            return commandView(existing,a.include_map)
        elseif cls=='gap' then
            return fail('command_sequence_gap','Submit the next canonical command id.',
                {accepted=false,recovery='refresh_history',next_command_id=s.ledger:nextCommandId()})
        elseif cls~='accept' then
            return fail('command_ledger_hole','The command ledger is inconsistent.',{accepted=Json.null})
        end
        -- None of the checks below consume the sequence on failure.
        if not s.control_token or a.control_token~=s.control_token then return fail('control_lost') end
        if a.expected_revision~=s.revision then return fail('stale_revision','Observe the current state before acting.') end
        if s.active or s.execution then return fail('command_in_progress') end
        if nativePhase(s)~='ready' then return fail('not_ready') end
        local command={expected_revision=a.expected_revision,action=action,
            control_token=s.control_token,status='queued',protocol=4,
            input_owner='remote',responses={},response_count=0,consumed_interactions={},
            uncertain=false,snapshot_availability='not_captured'}
        s.ledger:accept(a.command_id,fingerprint,command)
        s.active=command
        s.game:onTickEnd(function() execute(s,command) end,'mcp_bridge_action')
        return commandView(command,a.include_map)
    elseif op=='respond' then
        if not stringId(a.command_id) or not stringId(a.interaction_id) or not stringId(a.response_id)
            or not integer(a.expected_revision,1,9007199254740991) then return fail('invalid_response') end
        local answer,code=Interactions.validateAnswer(a.answer)
        if not answer then return fail(code) end
        local seq=CommandLedger.parseSeq(a.command_id)
        if not seq then return fail('invalid_command_id') end
        if s.ledger:status(seq)=='expired' then
            return fail('command_history_expired','The parent command receipt is no longer retained.',
                {accepted=Json.null,uncertain=true,acceptance_scope='response',recovery='do_not_replay',command_id=a.command_id})
        end
        local command=s.ledger:get(seq)
        if not command then return fail('command_not_accepted','The parent command was not accepted in this session.',
            {accepted=false,acceptance_scope='response',recovery='observe_before_resubmit',command_id=a.command_id}) end
        local fingerprint=Actions.fingerprint({interaction_id=a.interaction_id,answer=answer},a.expected_revision)
        local existing=command.responses[a.response_id]
        if existing then
            if existing.fingerprint~=fingerprint then return fail('response_conflict') end
            return commandView(command,a.include_map,a.response_id)
        end
        if not s.control_token or a.control_token~=s.control_token then return fail('control_lost') end
        if s.active~=command or not command.invocation or command.input_owner~='remote' then return fail('interaction_not_owned') end
        if command.consumed_interactions[a.interaction_id] then return fail('interaction_consumed') end
        local h=Interactions.current(command.invocation)
        if not h or h.interaction_id~=a.interaction_id then return fail('interaction_expired') end
        if h.consumed or command.pending_response then return fail('interaction_consumed') end
        if a.expected_revision~=s.revision then return fail('stale_revision') end
        local prepared,code=Interactions.prepare(h,answer,meta(s))
        if not prepared then return fail(code) end
        if command.response_count>=Interactions.MAX_RESPONSES then
            revoke(s,'response_budget_exhausted')
            return fail('response_budget_exhausted')
        end
        local receipt={response_id=a.response_id,interaction_id=a.interaction_id,fingerprint=fingerprint,
            state='queued',handle=h,answer=answer,control_token=s.control_token}
        command.responses[a.response_id]=receipt;command.response_count=command.response_count+1
        command.consumed_interactions[a.interaction_id]=true
        command.last_response_id=a.response_id;command.pending_response=receipt;h.consumed=true
        s.ledger:touch(command.seq,receiptBytes(command))
        bump(s);receipt.queued_revision=s.revision
        s.game:onTickEnd(function() executeResponse(s,command,receipt) end,'mcp_bridge_response')
        return commandView(command,a.include_map,a.response_id)
    end
    return fail('unknown_operation')
end
local function receive(s,request)
    if state~=s then return end
    local ok,result,err=pcall(dispatch,s,request)
    local response={v=4,id=type(request.id)=='string' and request.id or Json.null}
    if not ok then
        revoke(s,'bridge_error');response.ok=false;response.error={code='bridge_error',message='The bridge could not process this request.'}
        print('[MCP Bridge] request error: '..tostring(result))
    elseif err then response.ok=false;response.error=err
    else response.ok=true;response.result=result end
    if s.transport then s.transport:send(response) end
end
local function start(s)
    if s.transport or now()<s.next_start then return end
    local settings=config and config.settings and config.settings.tome_mcp_bridge or {}
    if settings.enabled==false then return end
    if type(settings.token)~='string' or #settings.token==0 then
        if not s.config_warned then
            s.config_warned=true
            print('[MCP Bridge] Configure config.settings.tome_mcp_bridge.token to enable the local listener.')
            if s.game.log then s.game.log('#LIGHT_BLUE#MCP Bridge: configure tome_mcp_bridge.token before connecting.#LAST#') end
        end
        return
    end
    s.token=settings.token
    local transport,err=Transport.new{host='127.0.0.1',port=settings.port or 17646,max_message=262144,max_queue=1048576,
        onRequest=function(request) receive(s,request) end,
        onDisconnect=function(reason)
            if state==s then s.authenticated=false;revoke(s,'disconnected') end
        end}
    if transport then
        s.transport=transport
        print('[MCP Bridge] Listening on 127.0.0.1:'..tostring(settings.port or 17646))
    else
        s.next_start=now()+5000
        print('[MCP Bridge] Listener unavailable: '..tostring(err))
    end
end
function M.onFrame(g)
    if core and core.display and core.display.redrawingForSavefileScreenshot
        and core.display.redrawingForSavefileScreenshot() then return end
    local s=ensure(g)
    if s.pumping or s.tick_depth>0 then return end
    s.pumping=true
    local ok,err=pcall(function()
        sync(s);Input.attach(g);Journal.update(g);settle(s);start(s)
        if s.transport then s.transport:poll() end
    end)
    s.pumping=false
    if not ok then
        revoke(s,'bridge_error')
        print('[MCP Bridge] frame error: '..tostring(err))
    end
end
return M
