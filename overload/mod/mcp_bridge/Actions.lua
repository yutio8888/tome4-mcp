-- GPL-3.0-or-later. Protocol 3 only: native calls only; observations never run
-- talent callbacks. The legacy v1 talent whitelist and v2/v3 forks are gone.
local Json = require 'mod.mcp_bridge.Json'
local Progression = require 'mod.mcp_bridge.Progression'
local Items = require 'mod.mcp_bridge.Items'
local Tracker = require 'mod.mcp_bridge.InvocationTracker'
local Compat = require 'mod.mcp_bridge.NativeCompatibility'
local Distance = require 'mod.mcp_bridge.Distance'
local Details = require 'mod.mcp_bridge.ObservationDetails'
local M = {}
local attack_spec={target='actor',source='data/talents/misc/misc.lua',action_adapter='attack',
    description='Use the attack action with target_id to make a native ordinary attack, including native alternate attacks.'}
-- Native talents whose interaction callback resumes the talent body coroutine
-- directly (data/chats/command-staff.lua does coroutine.resume(co, true)).
-- That conflicts with the bridge's wrapped body coroutine and raises a native
-- Lua error which freezes the game; refuse them so an agent cannot trigger it.
local UNSUPPORTED_TALENT_INTERACTIONS={T_COMMAND_STAFF=true}
-- The command-staff chat resumes its own coroutine, which the tracker body
-- cannot tolerate; it is refused unless explicitly enabled (the chat seam then
-- runs it detached).
local function staffChatAllowed()
    return type(config)=='table' and type(config.settings)=='table'
        and type(config.settings.tome_mcp_bridge)=='table'
        and config.settings.tome_mcp_bridge.allow_command_staff==true
end
local function finite(value) return type(value)=='number' and value==value and value>-math.huge and value<math.huge end
local function stringId(value) return type(value)=='string' and #value>0 and #value<=256 and not value:find('%z') end
local function coordinate(value) return type(value)=='number' and value%1==0 and value>=0 and value<=2147483647 end
-- Statistical audit of an attack entry (NO-AUDIT): the only structural
-- requirement is a callable action + target with no post_action override. A
-- replaced-but-usable action/target is used; provenance is advisory.
local function auditAttack(player)
    local t=player.talents_def and player.talents_def[player.T_ATTACK or 'T_ATTACK']
    if type(t)~='table' or type(t.action)~='function' or type(t.target)~='function'
        or t.post_action~=nil then return nil,'attack_modified' end
    return attack_spec
end
function M.admit(player,id,mode)
    local t=player and player.talents_def and player.talents_def[id]
    local level=player and player.talents and player.talents[id]
    if not finite(level) or level<=0 then return nil,'talent_not_learned' end
    if type(t)~='table' or t.id~=id then return nil,'invalid_talent' end
    if UNSUPPORTED_TALENT_INTERACTIONS[id] and not staffChatAllowed() then return nil,'talent_interaction_unsupported' end
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
        base_cooldown=finite(t.cooldown) and t.cooldown or nil,
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
    elseif a.type == 'wait' or a.type=='change_level' or a.type=='auto_explore' then
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
        -- Internal auto-combat field: drive an actor-target talent through the
        -- native `force_target` path so every native target request resolves to
        -- the same bound actor (single actor-target lowering).
        if action.force_actor~=nil then
            if type(action.force_actor)~='boolean' then return nil,'invalid_force_actor' end
            a.force_actor,allowed.force_actor=action.force_actor,true
        end
        if action.force_grid~=nil then
            if type(action.force_grid)~='boolean' then return nil,'invalid_force_grid' end
            a.force_grid,allowed.force_grid=action.force_grid,true
        end
        -- Internal auto-combat field: the decided target answers EVERY native
        -- target request of this invocation (not only the first pre-filled
        -- prompt), so a talent whose message/action path asks for a target more
        -- than once cannot open an unanswerable native UI. The native
        -- range/self-warning guards are still evaluated per request.
        if action.authoritative_target~=nil then
            if type(action.authoritative_target)~='boolean' then return nil,'invalid_authoritative_target' end
            a.authoritative_target,allowed.authoritative_target=action.authoritative_target,true
        end
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
    if type(handler)~='function' then return {ok=false,code='change_level_unavailable',energy_spent=0} end
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
    -- Each command records its own native target geometry and target-cancel
    -- marker; clear any previous run.
    if type(command)=='table' then command.target_geometry=nil;command.target_cancelled=nil end
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
            local forceTarget=action.force_actor and target
                or (action.force_grid and action.x~=nil and action.y~=nil
                    and {x=action.x,y=action.y,__no_self=true}) or nil
            local function run() return p:useTalent(action.talent_id,nil,nil,nil,forceTarget,nil,true) end
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
                    -- `authoritative_target` (internal auto-combat lowering): the
                    -- decided target answers EVERY native getTarget request for
                    -- the whole invocation. A talent whose message path calls
                    -- getTarget before its action (Rush's `useTalentMessage`)
                    -- would otherwise consume the single one-shot prefill and
                    -- then open the real native targeting UI, which the
                    -- auto-combat slot cannot answer (P0 deadlock). Without the
                    -- flag the legacy one-shot prefill is preserved for remote
                    -- commands, whose later prompts are answerable interactions.
                    local prior=rawget(p,'getTarget')
                    local original=p.getTarget
                    if type(original)~='function' then return run() end
                    local authoritative=action.authoritative_target==true
                    local consumed=false
                    local function allowed(typ,x,y)
                        local map=g.level and g.level.map
                        if not map or not finite(x) or not finite(y) then return false,'invalid_target' end
                        if x<0 or y<0 or x>=map.w or y>=map.h then return false,'target_out_of_bounds' end
                        if type(typ)=='table' then
                            -- Preserve the native range guard.
                            if finite(typ.range) and finite(p.x) and finite(p.y)
                                and Distance.grid(p.x,p.y,x,y)>typ.range then return false,'target_out_of_range' end
                            -- Let the native UI raise its own self-target warning.
                            if x==p.x and y==p.y and typ.nowarning~=true and typ.talent~=nil then
                                return false,'self_target_warning'
                            end
                        end
                        return true
                    end
                    p.getTarget=function(self,typ,...)
                        -- Record the native target geometry once, for the agent
                        -- (beam/ball radius/self-fire). This is the spec the
                        -- native talent itself built, not a speculative run.
                        if command and type(typ)=='table' and not command.target_geometry then
                            local talent=type(typ.talent)=='string' and p.talents_def and p.talents_def[typ.talent] or nil
                            local shape=type(typ.type)=='string' and typ.type or 'unknown'
                            local scope,residual=Details.damageScope(shape,talent and talent.direct_hit,
                                talent and talent.radius or typ.radius)
                            command.target_geometry={shape=shape,
                                radius=finite(typ.radius) and typ.radius or nil,
                                range=finite(typ.range) and typ.range or nil,
                                selffire=Details.selffire({type=shape,selffire=typ.selffire,direct_hit=talent and talent.direct_hit}),
                                friendlyfire=Details.friendlyfire({type=shape,friendlyfire=typ.friendlyfire}),
                                piercing=typ.type=='beam' or nil,damage_scope=scope,
                                residual_area_radius=residual}
                        end
                        if consumed and not authoritative then return original(self,typ,...) end
                        consumed=true
                        if not authoritative then rawset(p,'getTarget',prior) end
                        local x,y,entity=resolve()
                        local ok,reason=allowed(typ,x,y)
                        if ok then return x,y,entity end
                        if authoritative then
                            -- A genuinely invalid target for this native request
                            -- is answered as a native target cancel (nil
                            -- coordinates). The native flow treats it as a
                            -- normal rejection; the executor slot never opens an
                            -- unanswerable targeting UI and never bypasses the
                            -- guard. The typed reason is surfaced by the caller.
                            if command then command.target_cancelled=reason end
                            return nil
                        end
                        -- Out of bounds/range or a native self-warning: fall back
                        -- to the real target request instead of bypassing it.
                        return original(self,typ,...)
                    end
                    local ok,value=pcall(run)
                    if authoritative or not consumed then rawset(p,'getTarget',prior) end
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
    -- An authoritative prefill that refused a genuinely invalid target request
    -- reports the typed guard reason instead of a generic native rejection.
    if command and command.target_cancelled and not success then
        result.code=command.target_cancelled
    end
    -- P3-2: a native rejection of an activated talent whose own cooldown is
    -- still running carries structured, client-visible cooldown info through the
    -- already-declared `missing` array (no protocol/schema widening). The
    -- remaining turns are read from the live `talents_cd` scalar.
    if not success and interactive and action.type=='use_talent' then
        local remaining=p.talents_cd and p.talents_cd[action.talent_id]
        if finite(remaining) and remaining>0 then
            result.missing={{kind='cooldown',talent=action.talent_id,
                remaining=remaining,required=0}}
            result.hint='talent on cooldown; wait for the listed turns before retrying'
        end
    end
    -- A move that neither changed position nor spent energy was blocked by
    -- terrain; report it distinctly instead of a silent success.
    if success and action.type=='move' and spent==0 and p.x==before_x and p.y==before_y then
        return {ok=false,code='blocked',energy_spent=0,native_return=ret}
    end
    return result
end
return M
