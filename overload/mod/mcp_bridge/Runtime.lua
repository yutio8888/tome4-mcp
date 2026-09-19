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
local NativeActivity=require 'mod.mcp_bridge.NativeActivity'
local ActorCombat=require 'mod.mcp_bridge.ActorCombat'
local Distance=require 'mod.mcp_bridge.Distance'
local CommandLedger=require 'mod.mcp_bridge.CommandLedger'
local ErrorRegistry=require 'mod.mcp_bridge.ErrorRegistry'
local ObservationViews=require 'mod.mcp_bridge.ObservationViews'
local ObservationCollections=require 'mod.mcp_bridge.ObservationCollections'
local LevelMap=require 'mod.mcp_bridge.LevelMap'
local AutoCombat=require 'mod.auto_combat.AutoCombatService'
local AutoCombatHost=require 'mod.auto_combat.AutoCombatHost'
local PolicySchema=require 'mod.auto_combat.PolicySchema'
local AdapterCatalog=require 'mod.auto_combat.AutoCombatCatalog'
local Guard=require 'mod.auto_combat.AutoCombatGuard'
local EffectManifest=require 'mod.auto_combat.EffectManifest'
local ManifestDrift=require 'mod.auto_combat.EffectManifestDrift'
local MovementPlanner=require 'mod.auto_combat.MovementPlanner'
local buildAutoCombatHost
local function sortedKeys(t)
    local out={}
    for key in pairs(t) do out[#out+1]=key end
    table.sort(out)
    return out
end
local AUTO_PREDICATES=sortedKeys(PolicySchema.PREDICATES)
local AUTO_SELECTORS=sortedKeys(PolicySchema.SELECTORS)
local AUTO_DESTINATION_SELECTORS=sortedKeys(PolicySchema.DESTINATION_SELECTORS)
local AUTO_NO_ENEMY_MODES=sortedKeys(PolicySchema.NO_ENEMY_MODES)
local AUTO_LOW_HP_MODES=sortedKeys(PolicySchema.LOW_HP_MODES)
local AUTO_NEW_ENEMY_MODES=sortedKeys(PolicySchema.NEW_ENEMY_MODES)
local AUTO_COMPUTED_FIELDS=sortedKeys(PolicySchema.COMPUTED_FIELDS)
local M={MAX_RETAINED_COMMANDS=256,COMMAND_RECEIPT_BYTES=4194304,MAX_RECENT_SNAPSHOTS=16,SNAPSHOT_BYTE_BUDGET=4194304}
-- P0: the auto-combat executor may never wait unbounded on a native invocation.
-- A live auto invocation that does not settle within this bound (elapsed game
-- ticks / wall time / observed frames) is aborted with the typed `native_timeout`:
-- its native targeting UI is cancelled, the invocation/root released and the
-- lease handed back. The bound only covers "the native call never settles"; it
-- does not distinguish strategies and never aborts a settling native task.
M.AUTO_NATIVE_TIMEOUT_MS=15000
M.AUTO_NATIVE_TIMEOUT_TICKS=200
M.AUTO_NATIVE_TIMEOUT_FRAMES=600
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
    -- The native rest and run activities own their own popup (the rest dialog
    -- and the "Running..." auto-explore dialog); they are not a request for the
    -- agent to answer.
    local activity_dialog=s and NativeActivity.dialog(s.native_activity)
    for _,dialog in ipairs(g.dialogs or {}) do
        if not s or not s.native_activity or dialog~=activity_dialog then return true end
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
    -- AC-01: a live auto-combat invocation (outside the remote slot) is a
    -- settling native boundary; an errored one quarantines the session.
    local auto=s.auto_invocation
    if auto then
        if auto.error then return 'unavailable' end
        if auto.pending>0 or not auto.done then return 'settling' end
    end
    if busy(g,s) then return 'needs_input' end
    if s.saving or savefile_pipe and (savefile_pipe.saving
        or type(savefile_pipe.pipe)=='table' and #savefile_pipe.pipe>0
        or type(savefile_pipe.waiton)=='table' and next(savefile_pipe.waiton)~=nil)
        or s.changing then return 'settling' end
    if localCombat(s) then return 'unavailable' end
    if s.native_activity and NativeActivity.live(s.native_activity,p) then return 'settling' end
    if p~=s.player or g.level~=s.level or not p.player or p.resting or p.running
        or g.wasd_state and (g.wasd_state.cnt or 0)>0 then return 'unavailable' end
    if not g.paused or not p.energy or p.energy.value<(g.energy_to_act or 1000) then return 'settling' end
    if g.onTickEndExists and g:onTickEndExists() then return 'settling' end
    return 'ready'
end
local RELEASE_HINTS={unsupported_interaction='a native UI the bridge cannot drive is open; observe.dialogs lists it and it may be answered with tome.dismiss',
    terminal='the game reached a terminal state (for example death)',
    dialog='a native dialog took input ownership',
    scene_changed='the level or the controlled player changed',
    disconnected='the client transport disconnected',
    stopped='control was stopped explicitly',
    control_replaced='another client took control',
    saving='a native save is in progress'}
-- Human hints for common terminal command codes; the code stays authoritative.
local COMMAND_HINTS={native_rejected='the native action refused; see native_message or the player-visible log',
    blocked='the move did not change position and spent no energy',
    native_progression_rejected='the native level-up dialog refused; check the static prerequisites and point pools',
    native_progression_mismatch='the native level-up state after its callbacks and cleanup did not match the spending; re-observe the point pools and talent/stat state',
    explore_interrupted='native auto-explore stopped at a popup or notice; check observe interaction/dialogs and respond or dismiss',
    enemies_in_sight='a visible hostile blocks native auto-explore; escorts and allies do not',
    no_autoexplore='this zone or level forbids auto-explore',
    nothing_left='native auto-explore found no reachable unexplored tile',
    target_out_of_range='the target is outside the talent range',
    target_lost='the target id is stale or no longer visible on this level; re-observe actors and retry with the new id',
    target_not_adjacent='the target is not adjacent',
    insufficient_class_points='no class talent points remain',
    insufficient_generic_points='no generic talent points remain',
    not_enough_resource='not enough of the required resource',
    talent_not_learned='the talent is not learned from a stored point pool',
    respec_not_enabled='respeccing is disabled by configuration'}
local function meta(s)
    local controller=companion()
    local raw=controller and type(controller.observation)=='function' and controller.observation(s.game.player)
    local summary=type(raw)=='table' and {state=Details.text(raw.state,48),code=Details.text(raw.code,128),
        message=Details.text(raw.message,512),actions=Details.number(raw.actions)} or nil
    local phase=nativePhase(s)
    return {session_id=s.session_id,level_instance_id=s.level_id,revision=s.revision,protocol_version=4,
        history=s.ledger and s.ledger:history() or Json.null,
        phase=phase,actionable=(phase=='ready' and s.control_token~=nil
            and not (s.auto_combat and s.auto_combat.arbiter.owner=='auto_combat')) or false,
        control_lease=s.control_token and 'held' or 'released',
        needs_reconnect=(s.access_mode=='control' and not s.control_token and not s.native_error) and true or nil,
        recovery=s.native_error and 'fresh_load_required' or nil,
        release_reason=(not s.control_token) and s.release_reason or nil,
        native_activity=(function()
            local p=s.game and s.game.player
            if not p then return nil end
            local activity=s.native_activity
            if p.resting then return (activity and activity.kind=='rest' and activity.native_rest==p.resting) and 'rest_owned' or 'rest_unowned' end
            if p.running then return (activity and activity.kind=='auto_explore' and activity.native_run==p.running) and 'run_owned' or 'run_unowned' end
            return nil
        end)(),
        cancelled_native_activity=s.cancelled_native_activity,
        release_hint=(not s.control_token) and s.release_reason
            and (RELEASE_HINTS[s.release_reason] or 'control was released') or nil,
        lua_heap_kb=type(collectgarbage)=='function' and math.floor(collectgarbage('count') or 0) or nil,
        control_source=(s.auto_combat and s.auto_combat.arbiter.owner=='auto_combat') and 'auto_combat'
            or s.control_token and 'remote' or localCombat(s) and 'battle_companion' or 'manual',
        battle_companion=summary}
end
local function snapshot(s,radius,options)
    local m=meta(s)
    local result=Observer.capture(s.game,m,radius,options)
    result.history=s.ledger:history()
    result.collection_refs=ObservationCollections.refs()
    result.actionable=m.actionable
    result.control_lease=m.control_lease
    result.needs_reconnect=m.needs_reconnect
    result.release_reason=m.release_reason
    result.release_hint=m.release_hint
    result.lua_heap_kb=m.lua_heap_kb
    result.native_activity=m.native_activity
    result.cancelled_native_activity=m.cancelled_native_activity
    -- Bounded auto-combat summary (design 11.2); the decision ring stays in
    -- tome.policy_log so a plain observe stays cheap and deterministic.
    -- Stable, always-present auto-combat summary: clients can rely on the keys
    -- before activation, after a stop, and after death (never null).
    local ac=s.auto_combat and AutoCombat.status(s.auto_combat) or nil
    local run=ac and ac.run or nil
    result.auto_combat={enabled=(s.auto_combat and s.auto_combat.host_factory~=nil) or false,
        active=(ac and ac.active==true) or false,
        policy_id=(s.auto_combat and s.auto_combat.store.running and s.auto_combat.store.running.id) or Json.null,
        policy_hash=(ac and ac.running_hash) or Json.null,
        state=(run and run.state) or 'stopped',
        actions=(run and run.actions) or 0,
        paused_reason=((run and run.state=='paused') and run.reason) or Json.null,
        generation=(run and run.generation) or Json.null,
        last_decisions=(ac and ac.last_decisions) or Json.array{},
        -- P0/F4: the most recent bounded native-abort the executor performed
        -- (typed `native_timeout`). Stable key, null before any abort.
        last_native_abort=s.auto_timeout or Json.null}
    if s.session_root then
        local h=Interactions.current(s.session_root)
        if h then result.interaction=Interactions.describe(s.session_root,m) end
    end
    -- P0: while an auto-combat invocation is live, surface any native request it
    -- raised using the same describe shape as the manual slot (kind/shape/range/
    -- answer_types). The executor normally resolves these through the
    -- authoritative target lowering; this transparent fallback lets a caller see
    -- a request shape the executor cannot answer before the bounded abort fires.
    -- It is scoped inside `auto_combat` because the auto invocation is not the
    -- remote command slot (a plain `tome.respond` is not routed into it).
    if s.auto_invocation then
        local h=Interactions.current(s.auto_invocation)
        if h then
            result.auto_combat.pending_interaction=Interactions.describe(s.auto_invocation,m)
            -- S2 rev3/§6.2 (display only): when the prompt was handed back by a
            -- queue deviation, report the typed reason so the caller sees why the
            -- plugin is not answering it.
            local root=s.auto_invocation
            if root.sequence_deviation then
                result.auto_combat.pending_interaction.handed_back=true
                result.auto_combat.pending_interaction.handed_back_reason=
                    root.sequence_deviation.reason
            end
        end
    end
    result.events=Journal.capture(s.game,options and options.events_after)
    -- observe.sections: keep identity/metadata plus the requested domains only.
    if options and type(options.sections)=='table' and #options.sections>0 then
        local keep={}
        local sub={}
        local SUB={effects=true,sustains=true,resources=true,stats=true}
        for _,name in ipairs(options.sections) do
            keep[name]=true
            if SUB[name] then sub[name]=true end
        end
        local identity={session_id=true,level_instance_id=true,revision=true,world_tick=true,phase=true,
            actionable=true,control_lease=true,needs_reconnect=true,control_source=true,battle_companion=true,
            auto_combat=true,
            release_reason=true,release_hint=true,actor_id_scope=true,lua_heap_kb=true,
            native_activity=true,cancelled_native_activity=true,
            history=true,collection_refs=true,pending_command=true,interaction=true,interaction_scope=true,scene=true}
        for key in pairs(result) do
            if not identity[key] and not keep[key] and not (key=='player' and next(sub)) then result[key]=nil end
        end
        -- A player sub-field (effects/sustains/resources/stats) keeps the player
        -- container pruned to the requested fields plus its identity scalars.
        if next(sub) and not keep.player and type(result.player)=='table' then
            local core={id=true,name=true,x=true,y=true,level=true,life=true,max_life=true,faction=true,descriptor=true}
            for key in pairs(result.player) do if not core[key] and not sub[key] then result.player[key]=nil end end
        end
    end
    local root=invocation(s)
    if root then
        local command=root.command
        result.pending_command={command_id=command.command_id,status=command.status,
            input_owner=command.input_owner,execution_released=false,
            interaction=Interactions.describe(root,meta(s)),native_task=NativeTasks.describe(root)}
        -- A command-owned interaction (chat, quest, target) is also surfaced at
        -- the top level so a caller does not have to look inside pending_command.
        if not result.interaction and result.pending_command.interaction then
            result.interaction=result.pending_command.interaction
            result.interaction_scope='owned by the pending command; answer it with tome.respond'
        end
    end
    -- Lazily register an open native popup that the eager adoption could not
    -- see (the death menu builds its list UI after Dialog.init registers it).
    -- This is a read: the passive registration must not bump the revision.
    if not result.interaction and s.session_root and not s.native_error then
        local stack=s.game.dialogs
        local top=type(stack)=='table' and stack[#stack] or nil
        if top then
            local h=Interactions.adoptNative(top,s.session_root)
            if h then
                result.interaction=Interactions.describe(s.session_root,m)
                result.interaction_scope='native popup owned by the session; answer it with tome.dismiss'
            end
        end
    end
    return result
end
local function commandView(command,include_map,response_id,options_offset)
    local out={}
    for _,key in ipairs{'command_id','seq','status','code','energy_spent','native_return','world_tick_before',
        'world_tick_after','revision_before','revision_after','snapshot','snapshot_availability','interruption','uncertain',
        'turns_executed','max_turns','stop_reason','native_message','level_changed','target_geometry',
        'points_spent','points_returned','point_pool','previous_value','new_value','missing'} do out[key]=command[key] end
    -- action_ok is derived from the terminal status so it can never contradict
    -- it (a fatal blow reports status=failed, action_ok=false). A Lua
    -- `or` chain would collapse false to nil, so branch explicitly.
    if command.status=='completed' then out.action_ok=true
    elseif command.status=='failed' then out.action_ok=false
    else out.action_ok=nil end
    out.hint=command.hint or (command.code and COMMAND_HINTS[command.code]) or nil
    if type(command.missing)=='table' and #command.missing>0 then
        local parts={}
        for i=1,math.min(#command.missing,3) do
            local m=command.missing[i]
            if type(m)=='table' then
                if m.kind=='stat' then parts[#parts+1]='stat '..tostring(m.stat)..'>='..tostring(m.required)
                elseif m.kind=='level' then parts[#parts+1]='level>='..tostring(m.required)
                elseif m.kind=='talent' then parts[#parts+1]='talent '..tostring(m.talent)..'>='..tostring(m.required)
                elseif m.kind=='cooldown' then
                    parts[#parts+1]='cooldown '..tostring(m.talent)..': '..tostring(m.remaining)..' turn(s) remaining'
                elseif m.kind=='special' then parts[#parts+1]='native special requirement' end
            end
        end
        if #parts>0 then out.hint=(out.hint and (out.hint..'; ') or '')..'unmet: '..table.concat(parts,', ') end
    end
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
        -- A respond inherits its parent command's code; expose what it answered
        -- so code=level_changed after a chat answer is unambiguous.
        if response_id then out.parent_action=command.action and command.action.type or nil end
    end
    if command.native_rest then out.turns_executed=command.native_rest.cnt or 0 end
    -- A pending interaction can change life/actors; return a live snapshot so
    -- the caller does not mistake the pre-action snapshot for the current state.
    if command.protocol and command.status=='awaiting_input' and not out.snapshot and state then
        out.snapshot=snapshot(state)
        out.snapshot_scope='live'
    end
    if include_map~=true and out.snapshot then
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
            if s.session_root and root~=s.session_root then Interactions.reownAll(root,s.session_root) end
            NativeTasks.release(root);Interactions.release(root);Tracker.release(root)
            if s.execution==root then s.execution=nil end
            command.invocation=nil
        end
    end
    -- Retain deduplication metadata without retaining an entire old level.
    command.player,command.level,command.control_token=nil,nil,nil
    command.native_rest,command.rest_dialog=nil,nil
    if s.native_activity==command then s.native_activity=nil end
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
-- Activity stops are owned by NativeActivity; these thin wrappers keep the
-- existing Runtime call sites and only act on a registered activity.
local function stopRest(s,command,reason)
    if not command or command.kind~='rest' then return end
    NativeActivity.stop(s,command,reason)
    if command.stop_error then restFault(s,command) end
end
local function stopRun(s,command,reason)
    if not command or command.kind~='auto_explore' then return end
    NativeActivity.stop(s,command,reason)
end
-- A native rest/run started outside a bridge command leaves the session
-- permanently not_ready. Cancel it so the caller can act again.
local function clearUnownedNativeActivity(s)
    local p=s.game and s.game.player
    if not p then return false end
    local activity=s.native_activity
    local active_rest=activity and activity.kind=='rest' and activity.native_rest or nil
    local active_run=activity and activity.kind=='auto_explore' and activity.native_run or nil
    local cancelled=nil
    if p.resting and p.resting~=active_rest and type(p.restStop)=='function' then
        if pcall(p.restStop,p,'mcp_cancel') then cancelled='unowned_rest' end
    end
    if p.running and p.running~=active_run and type(p.runStop)=='function' then
        if pcall(p.runStop,p,'mcp_cancel') then cancelled='unowned_run' end
    end
    if cancelled then s.cancelled_native_activity=cancelled end
    return cancelled~=nil
end
local function revoke(s,reason,resumable_scene)
    local changed=s.control_token~=nil
    s.control_token=nil
    s.release_reason=reason
    local active=s.active
    if active and active.status=='queued' then
        bump(s);finish(s,active,'cancelled',reason)
    elseif active then
        active.interruption=reason;stopRest(s,active,reason);stopRun(s,active,reason)
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
            -- A popup the command owned (for example the death dialog) stays
            -- answerable by moving it to the session root once the command is
            -- terminal. Non-terminal revokes (stop/lease change) keep it on the
            -- command so respond/receipt semantics are preserved.
            if s.session_root and reason=='terminal' then Interactions.reownAll(root,s.session_root) end
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
    -- Policy authoring/certification surface. Execution is wired separately;
    -- the service reports execution_not_available until the host adapter lands.
    s.auto_combat=AutoCombat.new{}
    -- Planning-level dry runs only need audited reads, so this host is wired
    -- unconditionally and never depends on allow_auto_combat_execution.
    s.auto_combat.dry_run_host_factory=function(svc,policy) return buildAutoCombatReadHost(s,policy) end
    -- Replay-grade log metadata (design §10): the world tick, session revision
    -- and level instance are tagged on every decision-log entry.
    s.auto_combat.log_context=function()
        return {tick=(s.game and s.game.turn) or 0,revision=s.revision,level_instance_id=s.level_id}
    end
    -- A character carries its draft/approved policy; reading a character never
    -- resumes automatic action.
    if g.player and type(g.player.auto_combat_policy)=='table' then
        AutoCombat.loadState(s.auto_combat,g.player.auto_combat_policy)
    end
    -- Live execution is opt-in and experimental: the executor reuses
    -- Actions.execute under a synthetic command whose root must not hijack the
    -- remote command slot (the changed() guard below skips it).
    if config and config.settings and config.settings.tome_mcp_bridge
        and config.settings.tome_mcp_bridge.allow_auto_combat_execution==true then
        s.auto_combat.host_factory=function(svc) return buildAutoCombatHost(s,svc.store.running) end
    end
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
    -- Dialogs raised outside a talent body (sealed door, lore, running, death)
    -- belong to the control session and are answered with tome.dismiss.
    s.session_root={game=g,interactions={},
        command={command_id='session',status='session',input_owner='remote',
            responses={},consumed_interactions={},interaction_sequence=0}}
    -- nativeOwner()/Tracker.callback expect a node with `.root`.
    s.session_node={root=s.session_root}
    local function changed(root)
        if state==s and root and root.game==g then
            -- Auto-combat roots are tracked for their own pending work but never
            -- become the remote invocation slot.
            if root~=s.session_root and not (root.command and root.command.auto_combat) then
                s.execution=root
            elseif root.command and root.command.auto_combat then
                -- AC-01: keep a live auto-combat root visible to nativePhase and
                -- the frame pump until it settles.
                s.auto_invocation=root
            end
            bump(s)
        end
    end
    Tracker.reset(changed);Interactions.reset(changed);NativeTasks.reset(changed)
    Input.attach(g)
end
local function ensure(g)
    if not state or state.game~=g then M.reset(g) end
    return state
end
function M.hasControl(player)
    local s=state
    if not s or s.game.player~=player then return false end
    if s.control_token~=nil or s.active~=nil or s.execution~=nil then return true end
    -- AC-07: the standalone auto-combat lease (and an owned native activity)
    -- must suppress ToME's native automaticTalents too.
    if s.auto_combat and s.auto_combat.arbiter.owner=='auto_combat' then return true end
    if s.native_activity and s.native_activity.owner=='auto_combat' then return true end
    return false
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
    if s.auto_combat then AutoCombat.manualInput(s.auto_combat,reason) end
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
    if not s then return true end
    return NativeActivity.beforeStep(s,player)
end
function M.afterRestStep(player,energy_before,task)
    if task then NativeTasks.afterStep(task,energy_before);return end
    local s=state
    if s then NativeActivity.afterStep(s,player,energy_before) end
end
function M.markRestInterruption(player,reason)
    local s=state
    if s and s.game.player==player then NativeActivity.markInterruption(s,reason) end
end
function M.onRestStop(player,message)
    local s=state
    if not s then return end
    return NativeActivity.onStop(s,player,message)
end
function M.afterRestStop(activity,was_stopping)
    NativeActivity.afterStop(activity,was_stopping)
end
function M.onRestStopError(activity)
    if state then NativeActivity.onStopError(state,activity) end
end
function M.beforeTick(g)
    local s=ensure(g);s.tick_depth=s.tick_depth+1
end
-- A native UI can be produced by an NPC while settling the one MCP action.
-- Only that active native tick can supply missing ownership; observer calls,
-- idle frames, pre-existing dialogs and manual handoffs cannot adopt a dialog.
function M.nativeUIOwner(g)
    local s=state
    if not s or s.game~=g or s.native_error then return end
    if s.tick_depth>0 then
        local command=s.active
        local root=command and command.invocation
        if root and not root.error and command.input_owner~='manual'
            and not command.handoff_requested and root.player==g.player
            and (root.level==g.level or root.transitioning)
            and (command.status=='executing' or command.status=='settling' or command.status=='running_native_task') then
            return root
        end
    end
    -- Dialogs raised outside a talent body (sealed door, lore, running, death)
    -- belong to the control session so tome.dismiss can answer them.
    if s.session_node and s.control_token and s.access_mode=='control' then return s.session_node end
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
        -- A dialog owned by the control session (raised outside a talent body:
        -- sealed door, lore, running, death) can be answered with tome.dismiss.
        if root==s.session_root and s.control_token and s.access_mode=='control' and not s.native_error then
            if not enter then Interactions.closeDialog(detail) end
            Interactions.exposeTop(root)
            return
        end
        -- A rest/run popup that belongs to the current native activity is not
        -- an unanswered interaction: own it (adopting the run popup passively).
        local activity=s.native_activity
        if activity then
            local ownership=NativeActivity.ownsDialog(s,activity,detail,enter)
            if ownership then
                if ownership=='passive' and activity.command and activity.command.invocation then
                    Interactions.adoptPassiveDialog(detail,{root=activity.command.invocation})
                end
                return
            end
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
        if enter and not root and s.access_mode=='control' and s.session_root and not s.native_error then
            -- Adopt even when the lease was already released (for example the
            -- death dialog raised after a terminal command).
            local h=Interactions.reown(detail,s.session_root) or Interactions.adoptNotice(detail,s.session_root)
            if h then
                Interactions.exposeTop(s.session_root)
                return
            end
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
        if command.kind=='auto_explore' then
            -- A native notice (trap/door/item) interrupted auto-explore. Stop the
            -- run and report a clean stop with the popup that caused it; keep the
            -- lease so the agent can observe it and answer with respond/dismiss.
            stopRun(s,command,'interaction')
            local top=s.game.dialogs and s.game.dialogs[#s.game.dialogs]
            if top then
                command.native_message=command.native_message or Details.text(top.title,128)
                command.stop_reason=command.stop_reason or 'native_popup'
            end
            finish(s,command,command.action_ok and 'completed' or 'failed','explore_interrupted')
        else
            local reason=command.handoff_requested or 'unsupported_interaction'
            revoke(s,reason);finish(s,command,'needs_input',reason)
        end
    elseif phase=='terminal' then
        revoke(s,'terminal');finish(s,command,'failed','terminal')
    elseif s.level~=command.level or s.player~=command.player then
        -- The command crossed a scene boundary: any popup it owned (for example
        -- the escort chat on the new level) belongs to the session now and must
        -- stay answerable after the command is released.
        if s.session_root and command.invocation then Interactions.reownAll(command.invocation,s.session_root) end
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
        if NativeActivity.is(command.kind) then
            finish(s,command,command.interruption and 'cancelled' or command.action_ok and 'completed' or 'failed',
                command.stop_reason or command.code)
        else finish(s,command,command.action_ok and 'completed' or 'failed',command.code) end
    end
end
-- Audited read-only reads shared by the live host and the planning dry-run
-- host. Nothing here runs a dynamic getter, RNG or talent callback.
local function autoCombatReads(s,policy,opts)
    local g=s.game
    local computed_memo
    local function lifePct(actor)
        if actor and Details.finite(actor.life) and Details.finite(actor.max_life) and actor.max_life>0 then
            return actor.life/actor.max_life*100
        end
    end
    -- AC-02: ToME stores resources as scalars with `min_<name>`/`max_<name>` and
    -- a `resources_def[<name>].talent` unlock gate, not `{current,max}`. Use the
    -- same audited projection semantics as ObservationDetails: a resource is
    -- only meaningful when its pool talent is known.
    local function resourceValue(actor,name)
        if not actor or type(name)~='string' then return nil end
        local value=actor[name]
        if not Details.finite(value) then return nil end
        local defs=actor.resources_def
        local def=type(defs)=='table' and defs[name] or nil
        local talent=type(def)=='table' and def.talent or nil
        if talent~=nil and not (type(actor.talents)=='table' and actor.talents[talent]~=nil) then
            return nil
        end
        return value
    end
    local function resourcePct(actor,name)
        local value=resourceValue(actor,name)
        if value==nil then return nil end
        local max=Details.number(actor['max_'..name])
        if max==nil or max<=0 then return nil end
        local pct=value/max*100
        if pct<0 then pct=0 elseif pct>100 then pct=100 end
        return pct
    end
    -- NO-AUDIT (v1.6): advisory source/identity telemetry only. It is computed
    -- for logging and never gates a decision (the guard calls the live builders
    -- directly). `opts.drift` lets a headless caller inject a record.
    local function manifestDrift()
        local override=opts and opts.drift
        if type(override)=='function' then return override() end
        local has_md5,md5=pcall(require,'md5')
        local reader=type(fs)=='table' and type(fs.readAll)=='function' and fs.readAll or nil
        local digest=has_md5 and type(md5.sumhexa)=='function' and md5.sumhexa or nil
        return ManifestDrift.telemetry({sources=EffectManifest.SOURCES,read=reader,
            digest=digest,expected={game_version=EffectManifest.GAME_VERSION},
            manifest=EffectManifest,identity=function(talent)
                local def=g.player and g.player.talents_def
                return type(def)=='table' and def[talent] or nil
            end})
    end
    -- Audited effective talent level (`self:getTalentLevel(t)`). Called directly
    -- as a normal entrypoint (no identity gate); an unavailable/erroring getter
    -- returns 'unknown' so the variant stays conservative.
    local function effectiveTalentLevel(talent,def)
        local p=g.player
        if type(p)~='table' or type(p.getTalentLevel)~='function' then return 'unknown' end
        if type(def)~='table' then return 'unknown' end
        local ok,value=pcall(p.getTalentLevel,p,def)
        if not ok or type(value)~='number' or value~=value then return 'unknown' end
        return value
    end
    -- `self:attr(id)` called directly. A successful read is definite; a missing
    -- or erroring method means the value is not obtainable (`known=false`).
    local function auditedAttr(id)
        local p=g.player
        if type(p)~='table' or type(p.attr)~='function' then return nil,false end
        local ok,value=pcall(p.attr,p,id)
        if not ok then return nil,false end
        return value,true
    end
    -- MAF-REV-06 (no-strict-audit): planning uses the game's actual getters and
    -- builders as normal entrypoints. There is no identity/digest/closure gate —
    -- Lua is dynamic and another addon may replace any function. A getter that
    -- errors, is missing or returns nil means the value is not obtainable, which
    -- the factory maps to `movement_derivation_unknown` / an unknown variant axis.
    -- Source digests remain advisory metadata only and never block a decision.
    local function auditedTalentGetter(talent,name)
        local p=g.player
        local def=type(p)=='table' and type(p.talents_def)=='table' and p.talents_def[talent] or nil
        if type(def)~='table' then return nil,'definition_missing' end
        local getter=def[name]
        if type(getter)~='function' then return nil,'getter_missing' end
        local called,value=pcall(getter,p,def)
        if not called or type(value)~='number' or value~=value then return nil,'getter_failed' end
        return value
    end
    -- Live target builder geometry. Only an allowlisted subset is copied; the
    -- builder never supplies actor/grid semantics or prompt order (those stay
    -- curated). A missing/erroring/non-table builder is a derivation unknown.
    local function auditedTargetGeometry(talent)
        local p=g.player
        local def=type(p)=='table' and type(p.talents_def)=='table' and p.talents_def[talent] or nil
        if type(def)~='table' then return nil,'definition_missing' end
        local builder=def.target
        local typ
        if type(builder)=='table' then typ=builder
        elseif type(builder)=='function' then
            local called,value=pcall(builder,p,def)
            if not called or type(value)~='table' then return nil,'builder_failed' end
            typ=value
        else
            return nil,'builder_missing'
        end
        local function num(v) return type(v)=='number' and v==v and v or nil end
        return {shape=type(typ.type)=='string' and typ.type or nil,
            range=num(typ.range),radius=num(typ.radius),
            pass_terrain=typ.pass_terrain==true or nil,
            requires_knowledge=typ.requires_knowledge==true or nil,
            nolock=typ.nolock==true or typ.no_lock==true or nil,
            selffire=num(typ.selffire),friendlyfire=num(typ.friendlyfire)}
    end
    -- Player-known occupancy of one grid: 'empty'|'actor'|'unknown'. A cell that
    -- is not currently visible is 'unknown' and its ACTOR slot is never read, so
    -- no hidden actor is probed.
    local function knownOccupancy(x,y)
        local map=g.level and g.level.map
        local p=g.player
        if not map or type(map.map)~='table' or not Details.finite(x) or not Details.finite(y)
            or not Details.finite(map.w) or not Details.finite(map.h) then return 'unknown' end
        if x<0 or y<0 or x>=map.w or y>=map.h then return 'unknown' end
        if not Observer.terrainVisible(g,p,map,x,y) then return 'unknown' end
        local cell=map.map[x+y*map.w]
        if type(cell)~='table' then return 'unknown' end
        local actor=cell[map.ACTOR or 3]
        if actor==nil or actor==p then return 'empty' end
        if Observer.visible(g,actor) then return 'actor' end
        return 'unknown'
    end
    local reads={
        policy=policy,
        -- Advisory source/identity telemetry (NO-AUDIT): available for logging,
        -- never a gate. The guard and planner call live builders directly.
        manifestDrift=manifestDrift,
        effectiveTalentLevel=effectiveTalentLevel,
        phase=function()
            local p=g.player
            if not p or p.dead then return 'waiting_player' end
            local phase=nativePhase(s)
            if phase=='ready' then return 'ready' end
            if phase=='settling' then return 'settling' end
            return 'waiting_player'
        end,
        opportunity_id=function() return s.ready_serial end,
        origin=function() local p=g.player if p then return {x=p.x,y=p.y} end end,
        hp_pct=function() return lifePct(g.player) end,
        resource_pct=function(name) return resourcePct(g.player,name) end,
        resource_value=function(name) return resourceValue(g.player,name) end,
        talent_known=function(id)
            local p=g.player
            if not p or type(p.talents)~='table' then return nil end
            return p.talents[id]~=nil
        end,
        -- Desired sustain state. nil means the runtime cannot tell, so the
        -- controller skips maintenance rather than pausing.
        sustain_on=function(id)
            local p=g.player
            if not p or type(p.sustain_talents)~='table' then return nil end
            -- Native activation stores the sustain's return value, not always
            -- the boolean true; treat any non-nil, non-false value as on.
            return p.sustain_talents[id] and true or false
        end,
        cooldown_ready=function(id)
            local p=g.player
            if not p then return nil end
            local cooldown=p.talents_cd and p.talents_cd[id]
            if cooldown==nil then return true end
            if not Details.finite(cooldown) then return nil end
            return cooldown<=0
        end,
        -- P2.5: player-panel / tooltip-visible values. `computed` reads the
        -- audited ActorCombat getters (fail-closed to nil/unknown) and is
        -- memoized per session revision so a rule loop does not re-run the
        -- getter set on every predicate.
        computed=function(field)
            local p=g.player
            if not p then return nil end
            if not computed_memo or computed_memo.revision~=s.revision then
                computed_memo={revision=s.revision,values=ActorCombat.computed(p)}
            end
            return ActorCombat.field(computed_memo.values,field)
        end,
        -- Bounded visible effect scan. `who='target'` resolves the bound target
        -- the action will use. A missing/truncated list is `unknown`.
        has_effect=function(effect,who,bound_id)
            local p=g.player
            if not p then return nil end
            local actor
            if who=='target' then
                actor=bound_id and Observer.resolve(g,meta(s),bound_id) or nil
                if not actor then return nil end
            else
                actor=p
            end
            local list,truncated=Details.effects(actor,24)
            if truncated then return nil end
            local wanted=type(effect)=='string' and effect:lower() or ''
            for _,entry in ipairs(list or {}) do
                if entry.id==effect then return true end
                if type(entry.name)=='string' and entry.name:lower()==wanted then return true end
            end
            return false
        end,
        -- Bounded visible friendly/neutral actors (escorts, summons, allies),
        -- reusing the same visibility predicate as hostiles.
        allies=function()
            local p=g.player
            local out={}
            if not p or not g.level then return out end
            local session_meta=meta(s)
            for _,actor in pairs(g.level.entities or {}) do
                if actor~=p and type(actor)=='table' and actor.__is_actor
                    and not actor.dead and Observer.visible(g,actor)
                    and not NativeActivity.hostileVisible(g,p,actor) then
                    out[#out+1]={id=Observer.actorId(session_meta,actor),x=actor.x,y=actor.y,
                        hp_pct=lifePct(actor)}
                end
            end
            return out
        end,
        hostiles=function()
            local p=g.player
            local out={}
            if not p or not g.level then return out end
            local session_meta=meta(s)
            for _,actor in pairs(g.level.entities or {}) do
                if NativeActivity.hostileVisible(g,p,actor) then
                    out[#out+1]={id=Observer.actorId(session_meta,actor),x=actor.x,y=actor.y,hp_pct=lifePct(actor),
                        rank=Details.number(actor.rank),
                        level=actor.hide_level_tooltip and nil or Details.number(actor.level),
                        type=Details.text(actor.type,48)}
                end
            end
            return out
        end,
        -- Movement/reposition planner provider (MOV-1/MOV-3). Every fact is
        -- player-known: current FOV for `visible`, the native `remembers`/`seens`
        -- map knowledge for `remembered`, and the audited `Details.terrain`
        -- block status for `known_passable`. Hidden occupancy is never inspected;
        -- native collision is final authority and unknown stays unknown.
        plan=function(attempt)
            local entry=attempt.talent and EffectManifest.entry(attempt.talent) or nil
            local movement=entry and entry.movement or nil
            local map=g.level and g.level.map
            local player=g.player
            local function plannerTalentLevel(talent)
                local def=type(player)=='table' and type(player.talents_def)=='table'
                    and player.talents_def[talent] or nil
                return effectiveTalentLevel(talent,def)
            end
            local provider={
                origin=function()
                    if player and Details.finite(player.x) and Details.finite(player.y) then
                        return {x=player.x,y=player.y}
                    end
                end,
                anchor=function(name,bound_id)
                    if name=='self' then
                        if player and Details.finite(player.x) and Details.finite(player.y) then
                            return {x=player.x,y=player.y}
                        end
                        return nil
                    end
                    if name=='bound_target' then
                        if not bound_id then return nil end
                        local target=Observer.resolve(g,meta(s),bound_id)
                        if target and Details.finite(target.x) and Details.finite(target.y) then
                            return {x=target.x,y=target.y}
                        end
                    end
                    return nil
                end,
                talentLevel=plannerTalentLevel,
                -- Called directly (no identity gate); a missing/erroring reader
                -- means the value is not obtainable.
                attr=auditedAttr,
                talentGetter=auditedTalentGetter,
                builder=auditedTargetGeometry,
                occupancy=knownOccupancy,
                knowledge=function(x,y)
                    if not map or not Details.finite(x) or not Details.finite(y)
                        or not Details.finite(map.w) or not Details.finite(map.h) then
                        return {in_bounds=false}
                    end
                    if x<0 or y<0 or x>=map.w or y>=map.h then return {in_bounds=false} end
                    local index=x+y*map.w
                    local remembered=(map.remembers and map.remembers[index]) and true or false
                    local seen=(map.seens and map.seens[index]) and true or false
                    local visible=Observer.terrainVisible(g,player,map,x,y)
                    local known=remembered or seen or visible
                    local hazard='unknown'
                    local passable='unknown'
                    if known and type(map.map)=='table' then
                        local cell=map.map[index]
                        if type(cell)=='table' then
                            local terrain=cell[map.TERRAIN or 1]
                            local state=type(terrain)=='table' and Details.terrain(terrain,player) or nil
                            if state then
                                if state.blocked==true then passable=false
                                elseif state.blocked==false then passable=true end
                            end
                            local trap=cell[map.TRAP or 4]
                            if type(trap)=='table' then
                                -- Native Trap:knownBy: `all_know or known_by[actor]`.
                                local knownTrap=trap.all_know==true
                                if not knownTrap and type(trap.known_by)=='table' then
                                    knownTrap=trap.known_by[player] and true or false
                                end
                                if knownTrap then hazard=true end
                            end
                        end
                    end
                    return {in_bounds=true,visible=visible,remembered=(remembered or seen),
                        passable=passable,hazard=hazard}
                end,
            }
            local planned,err=MovementPlanner.plan({action=attempt.action,talent=attempt.talent,
                destination=attempt.destination,target_plan=attempt.target_plan,
                direction=attempt.direction,target=attempt.target,
                bound_target=attempt.bound_target,exclude=attempt.exclude},provider,movement)
            if not planned then return nil,err end
            return {plan=planned}
        end,
        notify=function() end,
        resources=function()
            local p=g.player
            if not p then return nil end
            return {life=Details.number(p.life),max_life=Details.number(p.max_life),
                positive=resourceValue(p,'positive'),negative=resourceValue(p,'negative'),
                stamina=resourceValue(p,'stamina')}
        end,
        snapshot_meta=function()
            return {revision=s.revision,level_instance_id=s.level_id}
        end,
    }
    reads.enemy_ids=function()
        local ids={}
        for _,entry in ipairs(reads.hostiles()) do ids[#ids+1]=entry.id end
        return ids
    end
    return reads
end

-- AC-01/AC-06 production outcome mapping: translates a real `Actions.execute`
-- result into the controller's host outcome. `reads.execute` is the only
-- production caller; exposed so a production-path test can assert that a real
-- `native_pending` is not collapsed into `ok`, and how `no_energy` + observed
-- delta classify an instant action.
function M.mapAutoCombatOutcome(result,action,noEnergy)
    if type(result)~='table' then return {status='error',code='no_result',energy_spent=false} end
    local spent=(Details.finite(result.energy_spent) and result.energy_spent>0) or false
    -- MFT-REV-06: scene-change evidence is independent of the success status.
    -- An uncertain exception may still have started/completed a level change;
    -- carry `level_changed` so the controller resets and requires a restart.
    --
    -- D-2: the structured refusal detail the command path already returns
    -- (`missing`/`hint`) and the native message are preserved (bounded, typed)
    -- so the auto policy log carries the same evidence as `tome.act`.
    local function scene(mapped)
        if result.level_changed then mapped.level_changed=true end
        if result.pending then mapped.pending=true end
        if type(result.missing)=='table' and #result.missing>0 then mapped.missing=result.missing end
        if type(result.hint)=='string' and #result.hint>0 then mapped.hint=result.hint end
        if type(result.native_message)=='string' and #result.native_message>0 then
            mapped.native_message=result.native_message
        end
        -- S2 ordered prompt-response queue evidence (internal auto-combat
        -- plumbing, never a protocol field): the observed prompt sequence, a
        -- typed deviation, and the reduced-trailing-optional marker.
        if type(result.target_sequence)=='table' then mapped.target_sequence=result.target_sequence end
        if type(result.sequence_deviation)=='table' then mapped.sequence_deviation=result.sequence_deviation end
        -- S2 rev3/§6.2: `handed_back` marks a LIVE prompt handed to the
        -- player/caller; the controller carries it as evidence (the typed reason
        -- drives the pause).
        if result.handed_back==true then mapped.handed_back=true end
        if result.reduced==true then
            mapped.reduced=true
            mapped.reduced_reason=result.reduced_reason
        end
        return mapped
    end
    if result.uncertain then
        return scene({status='uncertain',code=result.code,energy_spent=spent})
    end
    if result.code=='native_pending' then
        return scene({status='native_pending',code='native_pending',energy_spent=spent})
    end
    -- A pending scene confirmation (`change_level_pending`) opened a native
    -- dialog; it is not a completed transition and must hand the interaction
    -- back rather than be reported as a successful action.
    if result.code=='change_level_pending' then
        return scene({status='rejected',code='change_level_pending',energy_spent=spent})
    end
    if result.ok then
        local instant=false
        if action=='use_talent' or action=='set_sustain' then
            local zero=(result.energy_spent or 0)<=0
            if type(noEnergy)=='boolean' then instant=zero and noEnergy==true else instant=zero end
            if result.code=='already_in_desired_state' then instant=false end
        end
        return scene({status='ok',code=result.code,energy_spent=spent,instant=instant})
    end
    return scene({status='rejected',code=result.code,energy_spent=spent})
end

-- Live controller host. The executor reuses Actions.execute under a synthetic
-- command (see the changed() guard) and never becomes the remote invocation
-- slot.
buildAutoCombatHost=function(s,policy,opts)
    local g=s.game
    local reads=autoCombatReads(s,policy,opts)
    local effectiveTalentLevel=reads.effectiveTalentLevel
    -- NO-AUDIT (v1.6): call the live `self:spellFriendlyFire()` directly as a
    -- normal entrypoint. No digest/identity requirement: a replacement returning
    -- a usable number is used; an unavailable/erroring/non-finite value is
    -- `unknown` (the component then fails closed on its own value).
    local function dynamicSpellFriendlyFire()
        local p=g.player
        if type(p)~='table' or type(p.spellFriendlyFire)~='function' then return 'unknown' end
        local ok,value=pcall(p.spellFriendlyFire,p)
        if not ok or type(value)~='number' or value~=value then return 'unknown' end
        return value
    end
    local function dynamicScalar(name)
        if name=='spellFriendlyFire' then return dynamicSpellFriendlyFire() end
        return 'unknown'
    end
    local guard=Guard.build{
        game=g,policy=policy,source=g.player,
        resolve=function(id) return Observer.resolve(g,meta(s),id) end,
        allies=function() return reads.allies() end,
        visible=function(actor) return Observer.visible(g,actor) end,
        known=function(x,y)
            local map=g.level and g.level.map
            if map and type(map.remembers)=='function' and type(map.seens)=='function' then
                return (map:remembers(x,y) or map:seens(x,y)) and true or false
            end
            return nil
        end,
        getDef=function(talent)
            local def=g.player and g.player.talents_def
            return type(def)=='table' and def[talent] or nil
        end,
        blockPath=function(x,y)
            local map=g.level and g.level.map
            if map and type(map.checkEntity)=='function' then
                local ok,blocked=pcall(map.checkEntity,map,x,y,map.TERRAIN or 1,'block_move')
                return ok and blocked or false
            end
            return false
        end,
        details=Details,
        -- A native footprint context is supplied only when the engine geometry
        -- is actually loaded; otherwise the call is explicitly headless and the
        -- pure model is used. A supplied context that fails to expand is unknown
        -- (never silently the model).
        native=(type(core)=='table' and type(core.fov)=='table') and {game=g,source=g.player} or nil,
        talentLevel=effectiveTalentLevel,
        dynamicScalar=dynamicScalar,
    }
    local function safetyGuard(attempt)
        local ok,result=pcall(guard,attempt)
        if not ok then
            return {action='reject',reason='adapter_guard_error',
                detail={error=Details.text(tostring(result),160)}}
        end
        return result
    end
    reads.guard=safetyGuard
    reads.execute=function(attempt)
        -- Multi-turn native activities (design §15 P1b). They register the
        -- session activity and hold the next turns; the controller waits rather
        -- than resubmitting.
        if NativeActivity.is(attempt.action) then
            local activity={owner='auto_combat'}
            local result=NativeActivity.start(s,activity,attempt.action,{max_turns=attempt.max_turns})
            local spent=(Details.finite(result.energy_spent) and result.energy_spent>0) or false
            if result.uncertain then return {status='uncertain',code=result.code,energy_spent=spent} end
            if not result.ok then return {status='rejected',code=result.code,energy_spent=spent} end
            if NativeActivity.live(activity,s.game and s.game.player) then
                return {status='native_pending',code=result.code,energy_spent=spent}
            end
            return {status='ok',code=result.code,energy_spent=spent}
        end
        local target
        if attempt.bound_target then target=Observer.resolve(g,meta(s),attempt.bound_target) end
        local plan=attempt.plan
        local action
        if attempt.action=='attack' or attempt.talent=='T_ATTACK' then
            if not target then return {status='rejected',code='target_lost',energy_spent=false} end
            action={type='attack',target_id=attempt.bound_target}
        elseif attempt.action=='move' then
            -- The deterministic planner chose the adjacent delta (MOV-2); an
            -- explicit policy direction is the fallback. Native `moveDir` is
            -- still the final authority on collision/relocation.
            local direction=(plan and plan.kind=='step' and plan.direction) or attempt.direction
            if not (Details.finite(direction) and direction%1==0 and direction>=1 and direction<=9
                and direction~=5) then
                return {status='rejected',code='invalid_direction',energy_spent=false}
            end
            action={type='move',direction=direction}
        elseif attempt.action=='change_level' then
            -- Ordinary explicit policy action (v1.6). The audited native key
            -- handler decides terrain/wilderness/confirmation; a real scene
            -- transition is reported back so the controller pauses/resets.
            action={type='change_level'}
        elseif attempt.action=='use_talent' then
            action={type='use_talent',talent_id=attempt.talent}
            if plan and plan.kind=='sequence' then
                -- S2 ordered prompt-response queue: one native submission, one
                -- decided value per declared prompt. The executor answers the
                -- k-th native getTarget with the k-th entry's value (a grid
                -- coordinate, the caster cell or the bound actor) and keeps each
                -- request's own native range/self-warning guard. `sequence`
                -- implies the authoritative wrapper, so no one-shot prefill is
                -- consumed by a message-path prompt.
                action.sequence=plan.values
                if type(action.sequence)~='table' or #action.sequence==0 then
                    return {status='rejected',code='sequence_unavailable',energy_spent=false}
                end
            elseif plan and plan.kind=='grid' then
                action.x,action.y=plan.x,plan.y
                -- Grid lowering: answer every native target request with the
                -- requested coordinate (no entity). `authoritative_target` makes
                -- the decided coordinate answer every native request for this
                -- invocation, so a talent that asks for a target more than once
                -- (before and inside its action) cannot open an unanswerable UI.
                -- The bridge wrapper (not the engine `force_target` field, which
                -- is installed inside native `prepareUse`) evaluates the native
                -- range/self-warning guard for each request.
                action.authoritative_target=true
            elseif plan and (plan.kind=='none' or plan.kind=='self' or plan.kind=='native_random') then
                -- A no-target request (self/none/random) must not prefill an
                -- actor the policy did not ask for.
            elseif plan and (plan.kind=='actor' or plan.kind=='native_landing') then
                if not target then return {status='rejected',code='target_lost',energy_spent=false} end
                action.target_id=attempt.bound_target
                -- Single actor-target lowering: answer every native target
                -- request with the bound actor, not only the first pre-filled
                -- prompt. The native range/self-warning guard is re-evaluated for
                -- each request; a genuinely invalid request is answered as a
                -- native target cancel (typed reason), never bypassed.
                action.authoritative_target=true
            elseif target then
                -- An auto-slot actor-target talent without an explicit movement
                -- plan: the decided actor is authoritative for every native
                -- target request of this invocation. The auto slot cannot
                -- answer a native targeting UI (P0 Rush deadlock), so it drives
                -- the same wrapper the grid/actor plans use instead of the
                -- one-shot prefill used by remote commands.
                action.target_id=attempt.bound_target
                action.authoritative_target=true
            end
        elseif attempt.action=='set_sustain' then
            action={type='set_sustain',talent_id=attempt.talent,enabled=true}
        elseif attempt.action=='wait' then
            action={type='wait'}
        else
            return {status='rejected',code='unsupported_action',energy_spent=false}
        end
        -- AC-03: final reject-only guard immediately before native execution.
        local refusal=safetyGuard(attempt)
        if refusal then return {status='rejected',code=refusal.reason,energy_spent=false} end
        local command={command_id='auto-combat',status='auto_combat',auto_combat=true,
            interactions={},responses={},response_count=0,consumed_interactions={},interaction_sequence=0,
            rule=attempt.rule,action=action}
        local ok,root,result=pcall(Tracker.startAction,g,command,function()
            return Actions.execute(g,action,target,meta(s),command)
        end)
        -- S2: publish the observed prompt sequence and any typed deviation on the
        -- invocation root before it is reaped, so the abort/pause path and the
        -- controller can report them even when the action failed.
        if type(command)=='table' and root~=nil and type(root)=='table' then
            root.target_sequence=command.target_sequence
            root.sequence_deviation=command.sequence_deviation
            root.sequence_reduced=command.sequence_reduced or nil
            root.handed_back=command.target_handed_back or nil
            -- S2 rev3/§6.2 Path 1: when the action returned (ok), the deviation
            -- rides the mapped outcome and the controller checks it BEFORE its
            -- `native_pending` branch, so it is delivered inside this very step.
            -- Mark it so `reapAutoInvocation` does not deliver it a second time.
            -- If the pcall failed, leave it undelivered for Path 2.
            if ok and type(result)=='table' and command.sequence_deviation then
                root.deviation_delivered=true
            end
        end
        if type(root)=='table' and root.done then
            NativeTasks.release(root);Interactions.release(root);Tracker.release(root);root.invocation=nil
            if s.auto_invocation==root then s.auto_invocation=nil end
        end
        -- The auto-combat pump runs from Game:display, not from a native tick.
        -- A submitted action can clear `game.paused` through native useEnergy
        -- without a key event, and the core's tick loop then stays parked: the
        -- run freezes in `settling` (reproduced after the `recover` wait). The
        -- remote path gets this boundary tick from `onTickEnd`; the auto path
        -- has to request it explicitly so the game resumes and the pump can
        -- reach the next action opportunity.
        if core and core.game and type(core.game.requestNextTick)=='function' then
            core.game.requestNextTick()
        end
        if not ok then
            return {status='error',code='execution_error',energy_spent=false,
                message=Details.text(tostring(root),256)}
        end
        local def=g.player and g.player.talents_def and g.player.talents_def[action.talent_id]
        local noEnergy=type(def)=='table' and def.no_energy or nil
        if type(noEnergy)=='function' then noEnergy=nil end
        if type(noEnergy)~='boolean' then noEnergy=nil end
        return M.mapAutoCombatOutcome(result,action.type,noEnergy)
    end
    return AutoCombatHost.new(reads)
end

-- Planning-only host: the same audited reads without the executor, so dry_run is
-- available regardless of `allow_auto_combat_execution`.
buildAutoCombatReadHost=function(s,policy,opts)
    return AutoCombatHost.new(autoCombatReads(s,policy,opts))
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
    if NativeActivity.is(command.action.type) then
        command.owner='command'
        command.max_turns=command.action.max_turns;command.turns_executed=0
        result=NativeActivity.start(s,command,command.action.type,{max_turns=command.action.max_turns})
        if result.uncertain then
            command.uncertain=true
            NativeActivity.stop(s,command,'execution_error')
        elseif command.interruption then
            NativeActivity.stop(s,command,command.interruption)
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
    command.missing=result.missing;command.hint=result.hint
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
-- S2 rev3/§6.2: the handed-back auto-combat interaction is answerable by the
-- caller once the run stopped and the lease was released. Until then the auto
-- invocation is not a caller-owned negotiation target (the run is live and the
-- plugin may still answer its own prompts), so this returns nil while the lease
-- is held. The command-scoped respond/dismiss routes are tried first; this is the
-- fallback for the auto invocation (which has no command-ledger receipt).
local function autoHandbackHandle(s)
    local auto=s.auto_invocation
    if not auto then return nil end
    local owner=s.auto_combat and s.auto_combat.arbiter and s.auto_combat.arbiter.owner
    if owner=='auto_combat' then return nil end
    if s.auto_combat and s.auto_combat.controller
        and s.auto_combat.controller.state~='stopped' then return nil end
    return Interactions.current(auto)
end
local function fail(code,message,details)
    -- INT-02: every emitted code carries category/acceptance_scope/recovery
    -- (and accepted/uncertain defaults) from the generated registry.
    return nil,ErrorRegistry.envelope(code,message,details)
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
            -- Re-acquiring control atomically takes the auto-combat lease too:
            -- the run stops and the arbiter returns to manual (design 9/11.1).
            if s.auto_combat and s.auto_combat.arbiter.owner=='auto_combat' then
                AutoCombat.manualInput(s.auto_combat,'remote_takeover')
            end
            s.control_token=identifier('control');bump(s)
            local root=invocation(s)
            if root and s.active==root.command and root.player==s.game.player and root.level==s.game.level then
                if root.command.input_owner=='orphaned' then
                    root.command.input_owner='remote';root.command.control_token=s.control_token
                elseif root.command.input_owner=='manual' and not NativeTasks.current(root)
                    and #(s.game.dialogs or {})==0 then
                    -- The popup that forced the manual handoff is gone; reclaim.
                    root.command.input_owner='remote';root.command.control_token=s.control_token
                    root.command.handoff_requested=nil
                end
            end
        elseif invocation(s) then
            local command=invocation(s).command
            command.input_owner='manual';command.handoff_requested='observe_mode'
        end
        local snap=snapshot(s)
        local result={session_id=s.session_id,control_token=s.control_token or Json.null,revision=s.revision,mode=s.access_mode,
            protocol_version=4,history=s.ledger:history(),
            capabilities={protocol=4,actions=Json.array{'move','wait','attack','use_talent','set_sustain','use_item','change_level','rest','auto_explore',
                    'spend_stat','learn_talent','learn_category','unlearn_talent','pickup','equip','unequip'},
                connection_modes=Json.array{'control','observe'},
                talents=Actions.capabilities(s.game.player),
                talent_execution='native_interactive',
                interactions=Json.array{'target.grid','target.direction','dialog.confirm','dialog.choice','dialog.notice','inventory.select'},
                native_tasks=Json.array{'task.rest','task.auto_explore'},
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
                    auto_explore={implementation='supported',scope='native_explore'},
                    spend_stat={implementation='supported',scope='native_levelup'},
                    learn_talent={implementation='supported',scope='visible_known_categories',requirements='native_checked',detail_collection='progression_categories'},
                    learn_category={implementation='supported',scope='visible_known_or_lockable_categories',requirements='native_checked',detail_collection='progression_categories'},
                    unlearn_talent={implementation='limited',scope='native_last_learnt_window',reason='recent_window_only',enabled_by='settings.allow_respec'},
                    pickup={implementation='supported',scope='player_tile'},
                    equip={implementation='supported',scope='native_inventory_rules'},
                    unequip={implementation='supported',scope='native_inventory_rules'}},
                compact_responses=true,event_cursor=true,inventory_read=true,ground_items_read=true,
                progression_read=true,inspect_kinds=Json.array{'actor','character','talent','progression','item','compatibility'},
                auto_combat={available=true,
                    execution=(config and config.settings and config.settings.tome_mcp_bridge
                        and config.settings.tome_mcp_bridge.allow_auto_combat_execution==true) or false,
                    source='auto_combat',baseline='p1b',
                    actions=Json.array{'use_talent','attack','move','wait','rest','auto_explore','change_level'},
                    native_activities=Json.array{'rest','auto_explore'},
                    destination_selectors=Json.array(AUTO_DESTINATION_SELECTORS),
                    destination_accept={visibility={'visible','known','any'},
                        passability={'known_passable','native'},
                        hazard={'known_safe','avoid_known','any'},
                        landing={'deterministic','allow_random'}},
                    modes={on_no_enemy=Json.array(AUTO_NO_ENEMY_MODES),
                        on_low_hp=Json.array(AUTO_LOW_HP_MODES),
                        on_new_enemy=Json.array(AUTO_NEW_ENEMY_MODES)},
                    unsupported=EffectManifest.UNSUPPORTED,
                    adapter_version=AdapterCatalog.VERSION,
                    predicates=Json.array(AUTO_PREDICATES),
                    selectors=Json.array(AUTO_SELECTORS),
                    computed_fields=Json.array(AUTO_COMPUTED_FIELDS),
                    policy_ops=Json.array{'status','get','clear','validate','dry_run','set_draft','approve','activate','deactivate',
                        'start','stop','pause','resume','log','replay','presets','preset','export','import','import_assistant'}}},snapshot=snap}
        local ok,reason=Compat.check(s.game)
        result.capabilities.native_compatibility={compatible=ok==true,reason=reason,providers='runtime_checked'}
        if not ok then result.capabilities.talents=Json.array() end
        return result
    end
    if not s.authenticated then return fail('not_connected','Call connect with the configured token.') end
    if request.v~=4 then return fail('protocol_mismatch') end
    if a.session_id~=s.session_id then return fail('session_mismatch') end
    sync(s)
    if s.access_mode=='observe' and (op=='act' or op=='stop' or op=='respond' or op=='dismiss') then return fail('read_only_connection') end
    if a.include_map~=nil and type(a.include_map)~='boolean' then return fail('invalid_include_map') end
    if op=='observe' then
        if a.radius~=nil and not integer(a.radius,1,12) then return fail('invalid_radius') end
        if a.events_after~=nil and not integer(a.events_after,0,9007199254740991) then return fail('invalid_event_cursor') end
        if a.sections~=nil then
            if type(a.sections)~='table' or a.sections==Json.null then return fail('invalid_sections') end
            local allowed={player=true,map=true,ground=true,actors=true,talents=true,events=true,dialogs=true,
            scene=true,effects=true,sustains=true,resources=true,stats=true,ground_effects=true}
            for _,name in ipairs(a.sections) do
                if not allowed[name] then
                    return fail('invalid_sections',nil,{details={allowed_sections=Json.array{
                        'player','map','ground','actors','talents','events','dialogs','scene',
                        'effects','sustains','resources','stats','ground_effects'}}})
                end
            end
        end
        if a.detail~=nil and a.detail~='summary' and a.detail~='full' then return fail('invalid_detail') end
        return snapshot(s,a.radius,{include_map=a.include_map,events_after=a.events_after,sections=a.sections,detail=a.detail})
    elseif op=='inspect' then
        if not stringId(a.id) or type(a.kind)~='string' then return fail('invalid_inspect') end
        if a.target_id~=nil and not stringId(a.target_id) then return fail('invalid_inspect_target') end
        if a.x~=nil and not integer(a.x,0,2147483647) then return fail('invalid_inspect_target') end
        if a.y~=nil and not integer(a.y,0,2147483647) then return fail('invalid_inspect_target') end
        if a.computed~=nil and type(a.computed)~='boolean' then return fail('invalid_inspect') end
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
        if a.compact~=nil and type(a.compact)~='boolean' then return fail('invalid_compact') end
        local view=commandView(command,a.include_map,a.response_id,a.options_offset)
        if a.compact==true then
            -- Trim the large payload; revision/revision_before/after stay so the
            -- caller can tell the current revision from the command one.
            view.snapshot=nil;view.history=nil;view.collection_refs=nil
            view.revision_scope='current'
            view.compact=true
        end
        return view
    elseif op=='policy' then
        if type(a.policy_op)~='string' then return fail('invalid_argument','policy_op is required') end
        if s.access_mode~='control' and a.policy_op~='status' and a.policy_op~='log'
            and a.policy_op~='dry_run' and a.policy_op~='replay' and a.policy_op~='get'
            and a.policy_op~='import_assistant' then
            return fail('read_only_connection')
        end
        -- Assistant import may generate (read) on an observe connection, but
        -- storing the generated draft is a control-only write.
        if a.policy_op=='import_assistant' and a.store==true and s.access_mode~='control' then
            return fail('read_only_connection')
        end
        local result=AutoCombat.handle(s.auto_combat,a.policy_op,a)
        if not result.ok then
            local details=result.error and result.error.details
            if type(details)~='table' then details=details and {details=details} or nil end
            return fail(result.error.code,nil,details)
        end
        -- Persist the character-facing policy after a write; never the running
        -- state or control.
        if a.policy_op=='set_draft' or a.policy_op=='approve' or a.policy_op=='activate'
            or a.policy_op=='deactivate' or a.policy_op=='import' or a.policy_op=='clear'
            or (a.policy_op=='import_assistant' and a.store==true) then
            if s.game and s.game.player then
                s.game.player.auto_combat_policy=AutoCombat.saveState(s.auto_combat)
            end
        end
        result.ok=nil
        return result
    elseif op=='policy_log' then
        local result=AutoCombat.handle(s.auto_combat,'log',{limit=a.limit})
        if not result.ok then return fail(result.error.code) end
        result.ok=nil
        return result
    elseif op=='level_map' then
        if a.source~=nil and a.source~='native_map' then return fail('unsupported_map_source') end
        if a.format~=nil and a.format~='rows' and a.format~='region' then return fail('invalid_map_format') end
        local region=a.region
        if region~=nil or a.format=='region' then
            if type(region)~='table' or region==Json.null then return fail('invalid_region') end
            local result,code=LevelMap.region(s.game,meta(s),region)
            if not result then return fail(code) end
            return result
        end
        local result,code=LevelMap.capture(s.game,meta(s),a)
        if not result then return fail(code) end
        return result
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
            if not projection then
                local details={acceptance_scope='not_applicable'}
                if code=='invalid_filter' then details.details={allowed_filters=ObservationCollections.allowedFilters(req.collection)} end
                return fail(code,nil,details)
            end
            local page,capcode=s.views:capture{collection=req.collection,items=projection.items,
                complete=projection.complete,
                context={session_id=s.session_id,level_instance_id=s.level_id,connection_generation=s.connection_generation},
                revision=s.revision,page_size=req.page_size}
            if not page then return fail(capcode,nil,{acceptance_scope='not_applicable'}) end
            return page
        end
        return fail('invalid_request')
    elseif op=='dismiss' then
        if not s.control_token or a.control_token~=s.control_token then return fail('control_lost') end
        if s.native_error then return fail(s.native_error) end
        if not s.session_root then return fail('no_pending_interaction',nil,{details={hint='no native popup is waiting; observe.interaction lists one when present'}}) end
        local h=Interactions.current(s.session_root)
        if not h and s.active and s.active.invocation then
            -- A command-owned interaction (escort chat / quest popup on the new
            -- level) is answered by dismiss when respond is no longer valid, so
            -- the command can settle instead of deadlocking in awaiting_input.
            h=Interactions.current(s.active.invocation)
        end
        -- S2 rev3/§6.2: after a live handback the auto-combat run is stopped and
        -- the lease is released, so the handed-back prompt is player/caller-owned.
        -- Let `dismiss` resolve the auto invocation's current handle too. It
        -- grants nothing while the run is still live (autoHandbackHandle returns
        -- nil while the arbiter still owns auto-combat or the run is not stopped).
        if not h then h=autoHandbackHandle(s) end
        if not h then
            -- A native dialog the bridge never adopted (for example death) can
            -- still be closed through its own handler.
            local closed,close_code=Interactions.dismissTop(s.game)
            if closed then bump(s);return {dismissed=true,scope='native_dialog',snapshot=snapshot(s)} end
            return fail('dialog_not_closed','The native popup could not be closed by the bridge.',
                {details={hint='observe.interaction exposes selectable options when the popup is a list menu; '
                    ..'otherwise answer it with a native key. Last attempt: '..tostring(close_code)}})
        end
        if a.interaction_id~=nil and a.interaction_id~=h.interaction_id then
            return fail('interaction_expired',nil,{interaction_id=h.interaction_id})
        end
        if a.expected_revision~=nil and a.expected_revision~=s.revision then return fail('stale_revision') end
        local answer,code=Interactions.validateAnswer(a.answer)
        if not answer then return fail(code,nil,{interaction_id=h.interaction_id}) end
        local prepared,code=Interactions.prepare(h,answer,meta(s))
        if not prepared then return fail(code,nil,{interaction_id=h.interaction_id}) end
        local ok,err=pcall(Interactions.apply,h,prepared)
        if not ok then
            s.native_error=s.native_error or 'dismiss_error'
            return fail('dismiss_error',Details.text(err,512))
        end
        bump(s)
        return {dismissed=true,scope=h.root==s.session_root and 'session' or 'command',snapshot=snapshot(s)}
    elseif op=='abandon' then
        if not s.control_token or a.control_token~=s.control_token then return fail('control_lost') end
        -- Recovery for an isolated session, or for a pending command stuck in a
        -- manual handoff with no native task/dialog left to answer.
        local stuck_root=s.active and s.active.invocation
        local stuck=s.active~=nil and s.active.status~='executing'
            and not NativeTasks.current(stuck_root) and #(s.game.dialogs or {})==0
            and not Interactions.current(s.session_root)
            and not (stuck_root and Interactions.current(stuck_root))
        if not s.native_error and not stuck then
            return fail('not_isolated',nil,{details={hint='the session is not isolated; observe/act work normally'}})
        end
        local dropped=s.active and s.active.command_id or nil
        if s.active then
            stopRun(s,s.active,'abandoned');stopRest(s,s.active,'abandoned')
            s.active.status='failed';s.active.code='abandoned';s.active.snapshot=nil
            s.active.snapshot_availability='evicted'
        end
        s.active=nil;s.execution=nil
        s.native_error=nil;s.release_reason='abandoned'
        sync(s);bump(s)
        local phase=nativePhase(s)
        return {recovered=true,abandoned_command=dropped,phase=phase,
            recovery=phase=='ready' and 'discarded_failed_invocation' or 'wait_for_ready',
            release_reason='abandoned',
            details={hint=phase=='ready' and 'the failed invocation was discarded; the game state was not rolled back'
                or 'the game is still settling a native action; wait for phase ready before acting'},
            snapshot=snapshot(s)}
    elseif op=='stop' then
        if not s.control_token or a.control_token~=s.control_token then return fail('control_lost') end
        clearUnownedNativeActivity(s)
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
        -- Owner exclusivity: while auto-combat holds the lease the remote must
        -- reconnect control (which atomically takes it over) before acting.
        if s.auto_combat and s.auto_combat.arbiter.owner=='auto_combat' then
            return fail('control_conflict','Auto-combat holds control; reconnect control to take it over.',
                {accepted=false,recovery='connect_explicitly'})
        end
        if not s.control_token or a.control_token~=s.control_token then return fail('control_lost') end
        if a.expected_revision~=s.revision then return fail('stale_revision','Observe the current state before acting.') end
        if s.active or s.execution then return fail('command_in_progress') end
        if nativePhase(s)~='ready' then
            -- An unowned native rest/run would otherwise make the session
            -- permanently not_ready; cancel it once and re-check.
            if clearUnownedNativeActivity(s) then sync(s);bump(s) end
            if nativePhase(s)~='ready' then
                return fail('not_ready','The game is not ready for actions.',
                    {details={hint='an unowned native rest/run is active; it was cancelled if possible, observe again'}})
            end
        end
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
        -- S2-R3-02: the fingerprint is computed BEFORE both routes (the ledger
        -- branch and the auto-handback branch), so a reused response_id is
        -- classified with the real fingerprint of THIS request — never as a
        -- Lua global (the previous bug resolved `fingerprint` as a global).
        -- Same formula and same revision input as the command-scoped route.
        local fingerprint=Actions.fingerprint({interaction_id=a.interaction_id,answer=answer},a.expected_revision)
        local command=s.ledger:get(seq)
        if not command then
            -- S2 rev3/§6.2: an auto-combat handback has no ledger receipt (its
            -- command is `auto-combat`, never registered). When the run is stopped
            -- and the lease released, answer the auto invocation's current
            -- handle directly. Every existing guard still applies: the control
            -- token, the interaction id match, the consumed/response-budget
            -- bounds and the expected revision.
            local auto=s.auto_invocation
            -- S2-R4-02: consult the retained auto-command response receipts
            -- BEFORE requiring the request to name the CURRENT live handle. A
            -- successful target answer reissues a fresh interaction, so an exact
            -- retry of the successful response names the OLD (now superseded)
            -- interaction id yet must still classify as the recorded idempotent
            -- success; requiring the current handle first sent it to
            -- `command_not_accepted`. The receipt is compared by fingerprint, so
            -- a reused response_id with a different request is still
            -- `response_conflict`. The receipts live on the auto invocation's
            -- command, so they are retained exactly as long as the invocation is
            -- (and are dropped with it); the response budget still bounds how many
            -- fresh answers can be recorded.
            if auto then
                local autoCommand=auto.command or {}
                local entry=autoCommand.responses and autoCommand.responses[a.response_id]
                if entry then
                    if entry.fingerprint~=fingerprint then return fail('response_conflict') end
                    return {answered=true,scope='auto_combat',
                        interaction_id=entry.interaction_id or a.interaction_id,
                        response_id=a.response_id}
                end
            end
            local h=autoHandbackHandle(s)
            if h and a.interaction_id==h.interaction_id then
                local autoCommand=auto.command or {}
                -- The reused-response_id classification already happened above
                -- (before the current-handle requirement), so no receipt can
                -- remain unclassified here; the guards below are the fresh-answer
                -- path.
                if not s.control_token or a.control_token~=s.control_token then return fail('control_lost') end
                if autoCommand.consumed_interactions and autoCommand.consumed_interactions[a.interaction_id] then
                    return fail('interaction_consumed')
                end
                if h.consumed then return fail('interaction_consumed',nil,{interaction_id=h.interaction_id}) end
                if a.expected_revision~=s.revision then return fail('stale_revision') end
                local prepared2,code2=Interactions.prepare(h,answer,meta(s))
                if not prepared2 then return fail(code2,nil,{interaction_id=h.interaction_id}) end
                -- S2-R3-02: the command-scoped response budget applies unchanged:
                -- every auto-handback answer is counted on the auto command and
                -- bounded by `Interactions.MAX_RESPONSES`. The command route's
                -- extra `revoke` tears down a remote-owned command execution
                -- state that does not exist here (the auto lease is already
                -- released to manual), so the bound is enforced by refusing the
                -- answer without revoking the session.
                autoCommand.response_count=autoCommand.response_count or 0
                if autoCommand.response_count>=Interactions.MAX_RESPONSES then
                    return fail('response_budget_exhausted')
                end
                autoCommand.responses=autoCommand.responses or {}
                autoCommand.responses[a.response_id]={fingerprint=fingerprint,interaction_id=a.interaction_id}
                autoCommand.response_count=autoCommand.response_count+1
                autoCommand.consumed_interactions=autoCommand.consumed_interactions or {}
                autoCommand.consumed_interactions[a.interaction_id]=true
                local ok2,err2=pcall(Interactions.apply,h,prepared2)
                if not ok2 then
                    -- No new protocol/v4 code: the auto-handback answer failure
                    -- is the existing native-error surface (the command path also
                    -- records `native_error` and lets the caller re-observe).
                    s.native_error=s.native_error or 'dismiss_error'
                    return fail('dismiss_error',Details.text(err2,512),{interaction_id=h.interaction_id})
                end
                bump(s)
                return {answered=true,scope='auto_combat',interaction_id=h.interaction_id,response_id=a.response_id,snapshot=snapshot(s)}
            end
            return fail('command_not_accepted','The parent command was not accepted in this session.',
                {accepted=false,acceptance_scope='response',recovery='observe_before_resubmit',command_id=a.command_id})
        end
        local existing=command.responses[a.response_id]
        if existing then
            if existing.fingerprint~=fingerprint then return fail('response_conflict') end
            return commandView(command,a.include_map,a.response_id)
        end
        if not s.control_token or a.control_token~=s.control_token then return fail('control_lost') end
        if s.active~=command or not command.invocation or command.input_owner~='remote' then return fail('interaction_not_owned') end
        if command.consumed_interactions[a.interaction_id] then return fail('interaction_consumed') end
        local h=Interactions.current(command.invocation)
        if not h or h.interaction_id~=a.interaction_id then
            return fail('interaction_expired',nil,{interaction_id=h and h.interaction_id})
        end
        if h.consumed or command.pending_response then return fail('interaction_consumed',nil,{interaction_id=h.interaction_id}) end
        if a.expected_revision~=s.revision then return fail('stale_revision') end
        local prepared,code=Interactions.prepare(h,answer,meta(s))
        if not prepared then return fail(code,nil,{interaction_id=h.interaction_id}) end
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
        revoke(s,'bridge_error');response.ok=false
        response.error=ErrorRegistry.envelope('bridge_error','The bridge could not process this request.')
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
local function invariants(s)
    if s.ledger and s.ledger.W>s.ledger.H then return 'ledger_watermark' end
    if s.active and s.active.status=='queued' and s.active.execution_released then return 'queued_released' end
    if s.snapshots and #s.snapshots>M.MAX_RECENT_SNAPSHOTS then return 'snapshot_budget' end
    return nil
end
-- AC-01: release a settled auto-combat invocation so nativePhase stops
-- reporting it as a live boundary and the controller can resume.
local function reapAutoInvocation(s)
    local root=s.auto_invocation
    if not root or not root.done then return end
    if root.error then s.native_error=s.native_error or 'native_action_error' end
    -- S2 rev3/§6.2 Path 2 (belt-and-braces, exactly once): an ordered-queue
    -- deviation that was not delivered inside the submitting step (for example
    -- the native body settled without player input) is delivered here, before the
    -- root is released. The service records it, pauses with the typed reason,
    -- stops the run and revokes the auto lease. Runs in `onFrame` before the pump
    -- gate, so the pause lands before the next opportunity and the pending body
    -- can never become a fresh opportunity (the rule is never resubmitted).
    if root.sequence_deviation and not root.deviation_delivered and s.auto_combat then
        root.deviation_delivered=true
        AutoCombat.nativeDeviation(s.auto_combat,root.sequence_deviation)
    end
    NativeTasks.release(root);Interactions.release(root);Tracker.release(root)
    root.invocation=nil
    s.auto_invocation=nil
    bump(s)
end
-- P0: bounded abort of an auto-slot native invocation that never settled. The
-- executor cannot answer a native targeting UI, so an unresolved auto request
-- must end with a typed `native_timeout`: cancel the UI, release the invocation
-- and any pending native task, restore control to the player and record a typed
-- policy-log event (F4) with the action/talent/target and elapsed ticks/frames.
-- Only a leaf invocation is aborted; a live multi-turn native activity (rest /
-- auto_explore) is legitimate settling, not a stall.
local function abortAutoInvocation(s,started,elapsed)
    local root=s.auto_invocation
    if not root then return end
    if NativeTasks.current(root) then return end
    local command=root.command or {}
    local cancelled,reason
    -- S2 rev3/§6.2: live-handle-first. A still-live targeting UI is never
    -- "already answered", so a live handle is cancelled regardless of the
    -- `target_cancelled` marker. Only when no live handle exists may
    -- `target_cancelled` take the authoritative fast path (the queue genuinely
    -- answered nil and the native body is unwinding).
    local live=Interactions.current(root)
    if live and live.target then
        cancelled,reason=Interactions.cancelTarget(root)
        if cancelled and command.target_handed_back then reason='handed_back_timeout' end
    elseif command.target_cancelled then
        -- The executor's authoritative prefill already answered the native
        -- request with a cancel; the native body is unwinding, not stalled.
        cancelled=true;reason='authoritative_target_cancelled'
    else
        local target=Interactions.current(root)
        if target and target.target then
            cancelled,reason=Interactions.cancelTarget(root)
        else
            -- A non-target native request the executor cannot answer (for
            -- example a dialog). Close it through its own handler if possible.
            cancelled,reason=Interactions.dismissTop(s.game)
        end
    end
    elapsed=elapsed or {}
    local info={code='native_timeout',rule=command.rule,action=command.action and command.action.type,
        talent=command.action and command.action.talent_id,target=command.action and command.action.target_id,
        elapsed_ticks=elapsed.ticks,elapsed_frames=elapsed.frames}
    NativeTasks.release(root);Interactions.release(root);Tracker.release(root)
    Interactions.clearTargets(root)
    root.invocation=nil
    if s.auto_invocation==root then s.auto_invocation=nil end
    s.auto_invocation_started=nil;s.auto_invocation_frames=nil
    AutoCombat.nativeAbort(s.auto_combat,info)
    s.auto_timeout={code='native_timeout',reason=reason,cancelled=cancelled==true,
        action=info.action,talent=info.talent,target=info.target,
        elapsed_ticks=info.elapsed_ticks,elapsed_frames=info.elapsed_frames}
    bump(s)
end
-- Frame bookkeeping for the bounded abort. Returns true when the live auto
-- invocation exceeded the bound and was aborted this frame.
local function guardAutoInvocation(s)
    local root=s.auto_invocation
    if not root then s.auto_invocation_started=nil;s.auto_invocation_frames=nil;return false end
    -- A live multi-turn native task (rest / auto_explore) is legitimate
    -- settling, not a stalled leaf call: restart the bound and never abort it.
    if NativeTasks.current(root) then
        s.auto_invocation_started=nil;s.auto_invocation_frames=nil
        return false
    end
    s.auto_invocation_frames=(s.auto_invocation_frames or 0)+1
    local started=s.auto_invocation_started
    if not started then
        started={tick=s.game and s.game.turn or 0,ms=now(),frames=s.auto_invocation_frames}
        s.auto_invocation_started=started
    end
    local elapsed={ticks=(s.game and s.game.turn or 0)-started.tick,
        ms=now()-started.ms,frames=s.auto_invocation_frames-started.frames}
    if elapsed.ticks>=M.AUTO_NATIVE_TIMEOUT_TICKS or elapsed.ms>=M.AUTO_NATIVE_TIMEOUT_MS
        or elapsed.frames>=M.AUTO_NATIVE_TIMEOUT_FRAMES then
        abortAutoInvocation(s,started,elapsed)
        return true
    end
    return false
end
function M.onFrame(g)
    if core and core.display and core.display.redrawingForSavefileScreenshot
        and core.display.redrawingForSavefileScreenshot() then return end
    local s=ensure(g)
    if s.pumping or s.tick_depth>0 then return end
    s.pumping=true
    local ok,err=pcall(function()
        sync(s);Input.attach(g);Journal.update(g);settle(s);reapAutoInvocation(s);guardAutoInvocation(s);start(s)
        -- A live auto-combat activity owns the next turns; stop it if the run
        -- ended or lost the lease, then drop finished activities.
        local auto=s.auto_combat
        if s.native_activity and s.native_activity.owner=='auto_combat'
            and not (auto and auto.controller and auto.controller.state~='stopped') then
            NativeActivity.stop(s,s.native_activity,'auto_combat_stopped')
        end
        NativeActivity.reap(s)
        if s.auto_combat and s.auto_combat.host_factory and not s.active and not s.execution
            and not s.auto_invocation
            and not (s.native_activity and s.native_activity.owner=='auto_combat')
            and s.tick_depth==0 and s.tick_serial>0 then
            local ok_auto=pcall(AutoCombat.step,s.auto_combat)
            if not ok_auto then AutoCombat.manualInput(s.auto_combat,'execution_error') end
        end
        if s.transport then s.transport:poll() end
        -- STA-03: cheap invariant check after every frame's transitions.
        local violation=invariants(s)
        if violation then
            s.native_error=s.native_error or ('invariant_'..violation)
            revoke(s,s.native_error)
        end
    end)
    s.pumping=false
    if not ok then
        revoke(s,'bridge_error')
        print('[MCP Bridge] frame error: '..tostring(err))
    end
end

-- Local (in-game) auto-combat surface. The editor and the standalone form use
-- these directly; they never grant the MCP remote lease and never run without
-- explicit local authorization (`setAutoCombatExecution`).
local function persistAutoCombat(s)
    if s.game and s.game.player then
        s.game.player.auto_combat_policy=AutoCombat.saveState(s.auto_combat)
    end
end
function M.autoCombatStatus(g)
    local s=state
    if not s or s.game~=g then return nil end
    return AutoCombat.status(s.auto_combat)
end
function M.autoCombatHandle(g,op,args)
    local s=state
    if not s or s.game~=g then return {ok=false,error={code='no_session'}} end
    local result=AutoCombat.handle(s.auto_combat,op,args)
    if result.ok and (op=='set_draft' or op=='approve' or op=='activate'
        or op=='deactivate' or op=='import'
        or (op=='import_assistant' and args and args.store==true)) then
        persistAutoCombat(s)
    end
    return result
end
function M.autoCombatExecutionEnabled(g)
    local s=state
    if not s or s.game~=g then return false end
    return s.auto_combat and s.auto_combat.host_factory~=nil or false
end
-- Explicit local authorization to run native actions. This is the only path
-- that installs the live executor outside of configuration; it is deliberately
-- separate from `activate`, and it is never persisted into the character.
function M.setAutoCombatExecution(g,enabled)
    local s=state
    if not s or s.game~=g then return false end
    if enabled then
        if not s.auto_combat.host_factory then
            s.auto_combat.host_factory=function(svc) return buildAutoCombatHost(s,svc.store.running) end
        end
    else
        if s.auto_combat.controller and s.auto_combat.controller.state~='stopped' then
            s.auto_combat.controller:stop('execution_disabled')
        end
        s.auto_combat.controller=nil
        s.auto_combat.host_factory=nil
    end
    if config and config.settings and config.settings.tome_mcp_bridge then
        config.settings.tome_mcp_bridge.allow_auto_combat_execution=enabled and true or false
    end
    return true
end
-- Test/native fixture seam: build the production host (audited reads + real
-- executor) for the current session without installing the live pump.
function M.buildAutoCombatHostFor(g,policy,opts)
    local s=state
    if not s or s.game~=g then return nil end
    return buildAutoCombatHost(s,policy,opts)
end
-- Test/production seam: the read-only planning host for the current session.
function M.buildAutoCombatReadHostFor(g,policy,opts)
    local s=state
    if not s or s.game~=g then return nil end
    return buildAutoCombatReadHost(s,policy,opts)
end
function M.autoCombatService(g)
    local s=state
    if not s or s.game~=g then return nil end
    return s.auto_combat
end

-- production dispatch path — the same pcall(dispatch) + response envelope +
-- transport fan-out `receive` performs — and also return the response to the
-- caller. The auto-combat handback probe uses this to answer a live handed-back
-- prompt through the production respond/dismiss routing (never
-- Interactions.prepare/apply directly), so broken MCP routing fails the probe.
function M.bridgeRequestFor(g,request)
    local s=state
    if not s or s.game~=g then return {v=4,id=Json.null,ok=false} end
    local ok,result,err=pcall(dispatch,s,request)
    local response={v=4,id=type(request.id)=='string' and request.id or Json.null}
    if not ok then
        response.ok=false
        response.error=ErrorRegistry.envelope('bridge_error','The bridge could not process this request.')
        print('[MCP Bridge] request error: '..tostring(result))
    elseif err then response.ok=false;response.error=err
    else response.ok=true;response.result=result end
    if s.transport then s.transport:send(response) end
    return response
end
-- Test/native fixture seams for the S2 rev3 handback wiring: drive the production
-- pump's reap/abort steps and inspect/replace the live auto invocation without
-- installing the frame pump. They call the real production functions, so a test
-- asserts the same behaviour the pump has (no test-only reimplementation).
function M.autoInvocationFor(g)
    local s=state
    if not s or s.game~=g then return nil end
    return s.auto_invocation
end
function M.setAutoInvocationFor(g,root)
    local s=state
    if not s or s.game~=g then return nil end
    s.auto_invocation=root
    return root
end
function M.reapAutoInvocationFor(g)
    local s=state
    if not s or s.game~=g then return nil end
    reapAutoInvocation(s)
end
function M.abortAutoInvocationFor(g,started,elapsed)
    local s=state
    if not s or s.game~=g then return nil end
    abortAutoInvocation(s,started,elapsed)
end
-- The last bounded-abort record (`s.auto_timeout`), exposed so the production
-- abort test can assert the live-handle-first reason/cancelled flag.
function M.lastNativeAbort(g)
    local s=state
    if not s or s.game~=g then return nil end
    return s.auto_timeout
end
return M
