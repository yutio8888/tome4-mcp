-- GPL-3.0-or-later. Protocol 3 only: native calls only; observations never run
-- talent callbacks. The legacy v1 talent whitelist and v2/v3 forks are gone.
local Json = require 'mod.mcp_bridge.Json'
local Progression = require 'mod.mcp_bridge.Progression'
local Items = require 'mod.mcp_bridge.Items'
local Tracker = require 'mod.mcp_bridge.InvocationTracker'
local Compat = require 'mod.mcp_bridge.NativeCompatibility'
local Distance = require 'mod.mcp_bridge.Distance'
local M = {}
local attack_spec={target='actor',source='data/talents/misc/misc.lua',action_adapter='attack',
    description='Use the attack action with target_id to make a native ordinary attack, including native alternate attacks.'}
local function finite(value) return type(value)=='number' and value==value and value>-math.huge and value<math.huge end
local function stringId(value) return type(value)=='string' and #value>0 and #value<=256 and not value:find('%z') end
local function coordinate(value) return type(value)=='number' and value%1==0 and value>=0 and value<=2147483647 end
local function native(fn, suffix)
    if type(fn) ~= 'function' then return false end
    local info = debug.getinfo(fn, 'S')
    return info and type(info.source) == 'string' and info.source:sub(1, 1) == '@'
        and info.source:sub(-#suffix) == suffix
end
local function auditAttack(player)
    local t=player.talents_def and player.talents_def[player.T_ATTACK or 'T_ATTACK']
    if not t or not native(t.action,attack_spec.source) or not native(t.target,attack_spec.source)
        or t.post_action~=nil then return nil,'attack_modified' end
    return attack_spec
end
function M.admit(player,id,mode)
    local t=player and player.talents_def and player.talents_def[id]
    local level=player and player.talents and player.talents[id]
    if not finite(level) or level<=0 then return nil,'talent_not_learned' end
    if type(t)~='table' or t.id~=id then return nil,'invalid_talent' end
    if t.mode~=mode then return nil,'talent_mode_unsupported' end
    if mode=='activated' and type(t.action)~='function'
        or mode=='sustained' and (type(t.activate)~='function' or type(t.deactivate)~='function') then
        return nil,'talent_entrypoint_unavailable'
    end
    if not Compat.matches('useTalent',player.useTalent) then return nil,'talent_lifecycle_unavailable' end
    return t
end
function M.capabilities(player)
    local ids=Json.array()
    if not player then return ids end
    for id in pairs(player.talents or {}) do
        local t=player.talents_def and player.talents_def[id]
        if t and (t.mode=='activated' or t.mode=='sustained') and M.admit(player,id,t.mode) then ids[#ids+1]=id end
    end
    table.sort(ids)
    return ids
end
M.learnedTalents=M.capabilities
function M.describe(player, id)
    local t = player.talents_def and player.talents_def[id] or {}
    local admitted,reason=M.admit(player,id,t.mode=='sustained' and 'sustained' or 'activated')
    return {id=id, name=type(t.name)=='string' and t.name or id,
        level=player.talents and player.talents[id] or 0,
        cooldown=player.talents_cd and player.talents_cd[id] or 0,
        mode=type(t.mode)=='string' and t.mode or 'unknown',
        supported=admitted~=nil, unsupported_reason=reason,
        target='runtime', action_adapter=id=='T_ATTACK' and 'attack' or nil,
        instant=t.no_energy == true,
        activation={admitted=admitted~=nil,reason=reason,
            entrypoint=t.mode=='sustained' and 'set_sustain' or 'use_talent',interaction_coverage='runtime_checked'},
        description='Runs through native talent rules; input requests are discovered during execution.',
        sustained_active=player.sustain_talents and player.sustain_talents[id] and true or false}
end
-- Read-only talent query lives in its own pure module (spec QRY-01..09).
M.query=require('mod.mcp_bridge.TalentQuery').query
function M.validate(action)
    if type(action) ~= 'table' then return nil, 'invalid_action' end
    if Progression.isAction(action.type) then return Progression.validate(action) end
    if Items.isAction(action.type) then return Items.validate(action) end
    local a, allowed = {type=action.type}, {type=true}
    if a.type == 'move' then
        local d = action.direction
        if type(d) ~= 'number' or d%1~=0 or d<1 or d>9 or d==5 then return nil, 'invalid_direction' end
        a.direction, allowed.direction = d, true
    elseif a.type == 'wait' or a.type=='change_level' then
    elseif a.type == 'rest' then
        local limit=action.max_turns
        if limit==nil then limit=1000 end
        if not finite(limit) or limit%1~=0 or limit<1 or limit>1000 then return nil,'invalid_rest_limit' end
        a.max_turns,allowed.max_turns=limit,true
    elseif a.type == 'attack' then
        if not stringId(action.target_id) then return nil, 'invalid_target' end
        a.target_id, allowed.target_id = action.target_id, true
    elseif a.type == 'use_talent' then
        if not stringId(action.talent_id) then return nil,'invalid_talent_id' end
        a.talent_id,allowed.talent_id=action.talent_id,true
        local has_actor,has_position=action.target_id~=nil,action.x~=nil or action.y~=nil
        if has_actor and has_position then return nil,'conflicting_target' end
        if has_actor then
            if not stringId(action.target_id) then return nil,'invalid_target' end
            a.target_id,allowed.target_id=action.target_id,true
        elseif has_position then
            if not coordinate(action.x) or not coordinate(action.y) then return nil,'invalid_target_position' end
            a.x,allowed.x=action.x,true
            a.y,allowed.y=action.y,true
        end
    elseif a.type=='set_sustain' then
        if not stringId(action.talent_id) or type(action.enabled)~='boolean' then return nil,'invalid_sustain_action' end
        a.talent_id,a.enabled=action.talent_id,action.enabled
        allowed.talent_id,allowed.enabled=true,true
    else return nil, 'unsupported_action' end
    for key in pairs(action) do if not allowed[key] then return nil, 'unexpected_action_field' end end
    return a
end
function M.fingerprint(action, revision)
    -- Json.encode sorts object keys. Include every normalized field so a new
    -- action parameter cannot accidentally be left out of command deduplication.
    return tostring(revision)..'\0'..Json.encode(action)
end
local function blockedInteraction(g)
    return g.dialogs and #g.dialogs>0 or g.target_co or g.target and g.target.active
end
local function changeLevel(g)
    if blockedInteraction(g) then return {ok=false,code='player_busy',energy_spent=0} end
    local handler=g.key and g.key.virtuals and g.key.virtuals.CHANGE_LEVEL
    if not native(handler,'/mod/class/Game.lua') then return {ok=false,code='change_level_unavailable',energy_spent=0} end
    local p,previous_level,previous_zone=g.player,g.level,g.zone
    local before=p.energy.value
    -- This is the exact callback invoked by the native key command. It checks
    -- terrain, never_move, wilderness effects, terrain callbacks and the full
    -- changeLevel flow, including kill delay and transmutation confirmation.
    local ok,err=pcall(handler)
    local spent=math.max(0,before-p.energy.value)
    local changed=g.level~=previous_level or g.zone~=previous_zone
    if not ok then return {ok=false,code='execution_error',energy_spent=spent,uncertain=true,native_message=tostring(err),level_changed=changed} end
    if changed then return {ok=true,code='level_changed',energy_spent=spent,level_changed=true} end
    if blockedInteraction(g) then
        return {ok=true,code='change_level_pending',energy_spent=spent,level_changed=false,pending=true}
    end
    -- The native handler normally returns nil even on success; actual scene
    -- changes and pending native interaction, not its return value, decide.
    return {ok=false,code='native_rejected',energy_spent=spent,level_changed=false}
end
function M.execute(g, action, target, meta, command)
    local normalized,invalid=M.validate(action)
    if not normalized then return {ok=false,code=invalid,energy_spent=0} end
    action=normalized
    -- Each command records its own native target geometry; clear any previous run.
    if type(command)=='table' then command.target_geometry=nil end
    if Progression.isAction(action.type) then return Progression.execute(g,action) end
    if Items.isAction(action.type) then return Items.execute(g,action,meta) end
    if action.type=='rest' then return {ok=false,code='runtime_managed_action',energy_spent=0} end
    if action.type=='change_level' then return changeLevel(g) end
    local p = g.player
    local prefilling=action.type=='use_talent' and (action.target_id~=nil or action.x~=nil)
    if action.target_id and not prefilling and (not target or target==p or target.dead) then
        return {ok=false,code='target_lost',energy_spent=0}
    end
    if prefilling and action.target_id and not target then
        return {ok=false,code='target_lost',energy_spent=0}
    end
    if prefilling then
        -- Refuse a statically out-of-range prefill before starting the native
        -- talent. Dynamic ranges are re-checked in the getTarget wrapper.
        local t=p.talents_def and p.talents_def[action.talent_id]
        local static_range=type(t)=='table' and t.range
        local tx,ty=target and target.x or action.x,target and target.y or action.y
        if finite(static_range) and finite(tx) and finite(ty) and finite(p.x) and finite(p.y)
            and Distance.grid(p.x,p.y,tx,ty)>static_range then
            return {ok=false,code='target_out_of_range',energy_spent=0}
        end
    end
    if action.type == 'attack' and (math.abs(p.x-target.x)>1 or math.abs(p.y-target.y)>1) then
        return {ok=false,code='target_not_adjacent',energy_spent=0}
    end
    if action.type == 'attack' then
        if not auditAttack(p) then
            return {ok=false,code='attack_modified',energy_spent=0}
        end
    end
    local interactive=action.type=='use_talent' or action.type=='set_sustain'
    if interactive then
        local mode=action.type=='set_sustain' and 'sustained' or 'activated'
        local talent,reason=M.admit(p,action.talent_id,mode)
        if not talent then return {ok=false,code=reason,energy_spent=0} end
        local compatible,reason=Compat.check(g)
        if not compatible then return {ok=false,code=reason,energy_spent=0} end
        if action.type=='set_sustain' then
            local active=p.sustain_talents and p.sustain_talents[action.talent_id] and true or false
            if active==action.enabled then return {ok=true,code='already_in_desired_state',energy_spent=0,native_return=true} end
        end
    end
    local before = p.energy.value
    local before_x,before_y=p.x,p.y
    if not finite(before) then return {ok=false,code='invalid_native_energy',uncertain=true} end
    local ok, ret = pcall(function()
        if interactive then
            local function run() return p:useTalent(action.talent_id,nil,nil,nil,nil,nil,true) end
            local resolve
            if prefilling then
                resolve=function()
                    if action.target_id then return target.x,target.y,target end
                    return action.x,action.y,nil
                end
            end
            local root,result
            if resolve then
                root,result=Tracker.start(g,assert(command),function()
                    -- Prefill the first native getTarget once, then hand control
                    -- back to the native targeting code for any later request.
                    local prior=rawget(p,'getTarget')
                    local original=p.getTarget
                    if type(original)~='function' then return run() end
                    local consumed=false
                    local function allowed(typ,x,y)
                        local map=g.level and g.level.map
                        if not map or not finite(x) or not finite(y) then return false end
                        if x<0 or y<0 or x>=map.w or y>=map.h then return false end
                        if type(typ)=='table' then
                            -- Preserve the native range guard for the first request.
                            if finite(typ.range) and finite(p.x) and finite(p.y)
                                and Distance.grid(p.x,p.y,x,y)>typ.range then return false end
                            -- Let the native UI raise its own self-target warning.
                            if x==p.x and y==p.y and typ.nowarning~=true and typ.talent~=nil then return false end
                        end
                        return true
                    end
                    p.getTarget=function(self,typ,...)
                        if consumed then return original(self,typ,...) end
                        consumed=true
                        rawset(p,'getTarget',prior)
                        -- Record the native target geometry once, for the agent
                        -- (beam/ball radius/self-fire). This is the spec the
                        -- native talent itself built, not a speculative run.
                        if command and type(typ)=='table' and not command.target_geometry then
                            command.target_geometry={shape=type(typ.type)=='string' and typ.type or 'unknown',
                                radius=finite(typ.radius) and typ.radius or nil,
                                range=finite(typ.range) and typ.range or nil,
                                selffire=typ.selffire==true or nil,
                                piercing=typ.type=='beam' or nil}
                        end
                        local x,y,entity=resolve()
                        if allowed(typ,x,y) then return x,y,entity end
                        -- Out of bounds/range or a native self-warning: fall back
                        -- to the real target request instead of bypassing it.
                        return original(self,typ,...)
                    end
                    local ok,value=pcall(run)
                    if not consumed then rawset(p,'getTarget',prior) end
                    if not ok then error(value,0) end
                    return value
                end)
            else
                root,result=Tracker.start(g,assert(command),run)
            end
            return result
        elseif action.type=='move' then return p:moveDir(action.direction)
        elseif action.type=='wait' then p:waitTurn(); return true
        elseif action.type=='attack' then return p:useTalent(p.T_ATTACK,nil,nil,nil,target,nil,true)
        else return p:useTalent(action.talent_id,nil,nil,nil,target,nil,true) end
    end)
    if not finite(p.energy.value) then return {ok=false,code='invalid_native_energy',uncertain=true,
        native_message=not ok and tostring(ret) or nil} end
    local spent = math.max(0, before-p.energy.value)
    if not ok then return {ok=false,code='execution_error',energy_spent=spent,uncertain=true,native_message=tostring(ret)} end
    -- T_ATTACK returns true even when the underlying blow misses. A false
    -- talent result can spend energy during native pre-use failure; settle it.
    if command and command.invocation and command.invocation.pending>0 and not command.invocation.error then
        return {ok=true,code='native_pending',energy_spent=spent}
    end
    local success = ret and true or false
    local result={ok=success,code=success and 'action_complete' or 'native_rejected',energy_spent=spent}
    if type(ret)=='boolean' then result.native_return=ret end
    -- A move that neither changed position nor spent energy was blocked by
    -- terrain; report it distinctly instead of a silent success.
    if success and action.type=='move' and spent==0 and p.x==before_x and p.y==before_y then
        return {ok=false,code='blocked',energy_spent=0,native_return=ret}
    end
    return result
end
return M
