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
-- S2 ordered prompt-response queue: one internal decided value per declared native
-- prompt. The record is closed and every field is a scalar so command dedup
-- (`M.fingerprint`) stays deterministic and JSON-safe. `kind` is what the answer
-- *is* (`grid` coordinates with no entity, `self` the caster, `actor` the bound
-- actor); `request` is the declared prompt kind it answers, kept for the
-- expected/observed deviation report.
local SEQUENCE_KINDS={grid=true,self=true,actor=true}
-- A sequence entry is a real native prompt; `none` (no prompt at all) is a
-- `target_requests` value for single-request descriptors and is not a prompt
-- the queue can answer, so it is not part of the program vocabulary.
local SEQUENCE_REQUESTS={grid=true,self=true,actor=true}
-- The decided-value kind admissible for each declared prompt kind: an `actor`
-- prompt may be answered with the caster (`self`) or the bound actor; a `grid`
-- prompt only with coordinates (no entity); a `self` prompt with the caster
-- cell.
local SEQUENCE_VALUE_KINDS={actor={self=true,actor=true},grid={grid=true},
    self={self=true}}
-- The executor's internal carrier (`action.sequence`) also rides the curated
-- observed signature per entry (S2 rev3), so the runtime match uses the same
-- closed allowlist the factory validated. This is the decided value plus the
-- curation metadata for its position, never a policy/protocol field.
local SEQUENCE_OBSERVED_FLAGS={nolock=true,pass_terrain=true,friendlyblock=true,
    nowarning=true,immediate_keys=true,no_restrict=true}
local SEQUENCE_OBSERVED_STRINGS={first_target=true,msg=true}
local function normalizeObservedSignature(observed)
    if type(observed)~='table' then return nil end
    if type(observed.cursor_type)~='string' or #observed.cursor_type==0
        or #observed.cursor_type>32 then return nil end
    local copy={cursor_type=observed.cursor_type}
    for key in pairs(observed) do
        if key~='cursor_type' and key~='default_target'
            and not SEQUENCE_OBSERVED_FLAGS[key] and not SEQUENCE_OBSERVED_STRINGS[key] then
            return nil
        end
    end
    for flag in pairs(SEQUENCE_OBSERVED_FLAGS) do
        if observed[flag]~=nil then
            if type(observed[flag])~='boolean' then return nil end
            copy[flag]=observed[flag]
        end
    end
    for key in pairs(SEQUENCE_OBSERVED_STRINGS) do
        if observed[key]~=nil then
            if type(observed[key])~='string' or #observed[key]>512 then return nil end
            copy[key]=observed[key]
        end
    end
    if observed.default_target~=nil then
        if observed.default_target~='self' then return nil end
        copy.default_target='self'
    end
    return copy
end
-- S2 rev3: the observed prompt is matched against the entry's **curated
-- observed signature** (design §4.4). Cursor geometry is NOT a sound
-- actor/grid classifier (`hit` is "hit a single grid in LOS", `setSpot` fills
-- `target.entity` for every geometry, the cursor starts with the caster as
-- `entity`, and reviewed talents consume the same shapes with opposite
-- semantics), so the runtime evidence is a curated, closed set of STATIC
-- discriminators: `cursor_type` (the `typ.type` the reviewed action passes)
-- plus the boolean flags `nolock`/`pass_terrain`/`friendlyblock`/`nowarning`/
-- `immediate_keys`/`no_restrict`, and the bounded strings `first_target`/`msg`
-- and `default_target='self'`. Dynamic numerics (`range`/`radius`) and closures
-- are never signature fields (they are the per-request guard inputs). This is a
-- drift check on recorded fields, never an identity audit of a live object.
-- S2-R3-01 rev5 (presence-explicit semantics, normative): the signature is a
-- record, not a wildcard predicate.
--   * `cursor_type` is always an equality constraint;
--   * a DECLARED boolean flag must be PRESENT in the observed spec and equal
--     (`{cursor_type='hit'}` does not match a prompt that raises `nolock`; a
--     declared `nolock=false` requires the key present with value `false`,
--     distinct from absence — Vault's two prompts differ exactly by nolock
--     presence);
--   * an UNDECLARED boolean flag must NOT be raised by the observed spec;
--   * a declared string/`default_target` must be present and equal; when the
--     signature omits them the observed value is IGNORED — real flows raise
--     them nondeterministically (Phase Door's `first_target` is
--     rng.percent-driven, conveyance.lua:85), so they are never required-absent.
-- The normative runtime gate is the executor's EXACTLY-ONE rule: a raised
-- prompt may be answered only when exactly one declared entry — the arrival
-- position — matches it; zero matches, several matches, or a match at another
-- index are typed deviations that pause and hand the live prompt back.
local OBSERVED_FLAGS={nolock=true,pass_terrain=true,friendlyblock=true,
    nowarning=true,immediate_keys=true,no_restrict=true}
local OBSERVED_STRINGS={first_target=true,msg=true}
-- S2-R3-01 rev5: the runtime EXACTLY-ONE rule is the normative gate, so there
-- is no build-time exclusivity proof here: a published descriptor's factory
-- validation rejects only subsuming declarations, and the executor refuses to
-- answer any prompt that does not match EXACTLY the arrival entry (zero
-- matches, several matches, or a match at another index are typed handbacks).
local function observedMatchesSignature(typ,entry,caster)
    local signature=entry and entry.observed
    if type(signature)~='table' or type(signature.cursor_type)~='string' then return false end
    if type(typ)~='table' or type(typ.type)~='string' then return false end
    if typ.type~=signature.cursor_type then return false end
    -- Presence-explicit flags: declared -> present-and-equal; undeclared -> the
    -- observed spec must NOT raise the field.
    for flag in pairs(OBSERVED_FLAGS) do
        if signature[flag]~=nil then
            if typ[flag]~=signature[flag] then return false end
        elseif typ[flag]~=nil then return false end
    end
    -- Strings/default_target: declared -> present-and-equal; undeclared ->
-- ignored (real flows raise them nondeterministically, so they are never
    -- required-absent and never discriminate by absence).
    for key in pairs(OBSERVED_STRINGS) do
        if signature[key]~=nil and typ[key]~=signature[key] then return false end
    end
    if signature.default_target=='self' then
        if typ.default_target==nil or typ.default_target~=caster then return false end
    end
    return true
end
-- A spec the bridge cannot read as a signature at all (not a table, or no
-- string `type`) is the plugin's own observability boundary and is
-- `movement_request_kind_unknown`; a readable spec that matches no declared
-- entry is `unexpected_target_request` (design §6.1).
local function observableSpec(typ)
    return type(typ)=='table' and type(typ.type)=='string'
end
-- S2-FIX5: every emitted deviation record must carry its identifying fields so
-- a reader can always tell what happened (the live S2 playtest produced pause
-- records a reader could not interpret). `required` names the identifying
-- fields of each typed record; `M.validateDeviation` is the shared shape gate
-- and the executor asserts it at every emission site, so a malformed record
-- can never be stored on the command or surfaced on a result.
local DEVIATION_REQUIRED={
    unexpected_target_request={'expected','observed','skippable'},
    movement_request_kind_unknown={'expected','observed','skippable','handed_back'},
    movement_request_value_unknown={'expected','observed','index','request','dependency'},
}
function M.validateDeviation(record)
    if type(record)~='table' then return false,'record_not_table' end
    if type(record.reason)~='string' or record.reason=='' then return false,'missing_reason' end
    local required=DEVIATION_REQUIRED[record.reason]
    if not required then return false,'unknown_reason' end
    for _,key in ipairs(required) do
        if record[key]==nil then return false,'missing_'..key end
    end
    if record.expected~=nil and (type(record.expected)~='table'
        or type(record.expected.index)~='number') then return false,'invalid_expected' end
    if record.observed~=nil and (type(record.observed)~='table'
        or type(record.observed.index)~='number') then return false,'invalid_observed' end
    return true
end
local function assertDeviation(record)
    local ok,err=M.validateDeviation(record)
    if not ok then
        error('deviation record shape violated: '..tostring(err),2)
    end
    return record
end
M.SEQUENCE_VALUE_KINDS=SEQUENCE_VALUE_KINDS
function M.normalizeSequence(list)
    if type(list)~='table' then return nil,'invalid_sequence' end
    local maxKey,count=0,0
    for key in pairs(list) do
        if type(key)~='number' or key%1~=0 or key<1 then return nil,'invalid_sequence' end
        if key>maxKey then maxKey=key end
        count=count+1
    end
    if count~=maxKey or maxKey<1 or maxKey>8 then return nil,'invalid_sequence' end
    local out=Json.array()
    for i=1,maxKey do
        local entry=list[i]
        if type(entry)~='table' then return nil,'invalid_sequence' end
        local kind=entry.kind
        if not SEQUENCE_KINDS[kind] then return nil,'invalid_sequence' end
        if entry.request~=nil and not SEQUENCE_REQUESTS[entry.request] then return nil,'invalid_sequence' end
        local copy={kind=kind,request=entry.request or kind}
        -- S2 rev3: the executor matches each observed prompt against this
        -- entry's curated observed signature, so the carrier must carry it
        -- (every published sequence does; a missing one is fail-closed).
        local observed=normalizeObservedSignature(entry.observed)
        if not observed then return nil,'invalid_sequence' end
        copy.observed=observed
        if entry.optional~=nil then
            if type(entry.optional)~='boolean' then return nil,'invalid_sequence' end
            if entry.optional then copy.optional=true end
        end
        if kind=='grid' then
            if not coordinate(entry.x) or not coordinate(entry.y) then return nil,'invalid_sequence' end
            for key in pairs(entry) do
                if key~='kind' and key~='request' and key~='x' and key~='y' and key~='optional'
                    and key~='observed' then return nil,'invalid_sequence' end
            end
            copy.x,copy.y=entry.x,entry.y
        elseif kind=='actor' then
            if entry.target_id~=nil and not stringId(entry.target_id) then return nil,'invalid_sequence' end
            for key in pairs(entry) do
                if key~='kind' and key~='request' and key~='target_id' and key~='optional'
                    and key~='observed' then return nil,'invalid_sequence' end
            end
            if entry.target_id~=nil then copy.target_id=entry.target_id end
        else
            for key in pairs(entry) do
                if key~='kind' and key~='request' and key~='optional'
                    and key~='observed' then return nil,'invalid_sequence' end
            end
        end
        out[i]=copy
    end
    -- S2-R3-01 rev5: no carrier-level pairwise check — the runtime EXACTLY-ONE
    -- gate is the normative rule and subsumes it: even a directly submitted
    -- overlapping/identical signature pair can never be answered ambiguously,
    -- because a prompt is only answered when exactly the arrival entry matches.
    return out
end
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
        -- S2 ordered prompt-response queue (internal auto-combat field). A
        -- non-empty decided-value list answers the k-th native target request
        -- with the k-th value inside one submission; it implies the
        -- authoritative wrapper (the queue, not the one-shot prefill, owns every
        -- request). Closed and validated: an unknown kind, a malformed
        -- coordinate/actor, a hole or more than 8 entries is `invalid_sequence`.
        if action.sequence~=nil then
            local sequence,sequenceErr=M.normalizeSequence(action.sequence)
            if not sequence then return nil,sequenceErr end
            a.sequence,allowed.sequence=sequence,true
            a.authoritative_target,allowed.authoritative_target=true,true
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
    -- marker; clear any previous run. The S2 ordered-queue evidence
    -- (`target_sequence`) and deviations are per-invocation too.
    if type(command)=='table' then
        command.target_geometry=nil;command.target_cancelled=nil
        command.target_handed_back=nil
        command.target_sequence=nil;command.sequence_deviation=nil
        command.sequence_reduced=nil;command.sequence_reduced_reason=nil
    end
    if Progression.isAction(action.type) then return Progression.execute(g,action) end
    if Items.isAction(action.type) then return Items.execute(g,action,meta) end
    if action.type=='rest' then return {ok=false,code='runtime_managed_action',energy_spent=0} end
    if action.type=='change_level' then return changeLevel(g) end
    local p = g.player
    local prefilling=action.type=='use_talent'
        and (action.target_id~=nil or action.x~=nil or action.sequence~=nil)
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
                    -- S2 ordered prompt-response queue: the k-th observed native
                    -- request is matched against the k-th declared entry's
                    -- CURATED OBSERVED SIGNATURE and answered with that entry's
                    -- decided value. The queue lives inside this one submission;
                    -- it never resubmits the talent. A readable-but-unmatched
                    -- prompt (extra/reordered/signature-mismatched) is a LIVE
                    -- handback: the wrapper falls through to the real native
                    -- targeting UI and records `command.target_handed_back`
                    -- (never `target_cancelled`). An unreadable spec is
                    -- `movement_request_kind_unknown`, also a live handback. An
                    -- unevaluable value or a refused guard value is answered as
                    -- the existing native target cancel (the body unwinds; there
                    -- is no correct value to hand anyone).
                    local queue=(type(action.sequence)=='table' and #action.sequence>0)
                        and action.sequence or nil
                    local consumed=false
                    local observed=0
                    local yielded=false
                    -- S2-FIX5: whether this invocation actually ENTERED the
                    -- native targeting flow (a getTarget prompt was raised).
                    -- The queue's settle-time missing-entry rule is only
                    -- meaningful AFTER a prompt was raised: a native entry
                    -- that refuses before any prompt (cooldown / no energy /
                    -- on_pre_use `return false`) never starts the flow, so
                    -- there is no prompt to compare against and the ordinary
                    -- native outcome (native_rejected with its own detail)
                    -- applies — never a fabricated sequence deviation.
                    local raised=false
                    -- S2-REV-05: once a typed deviation is recorded on a LIVE
                    -- prompt, the queue stops answering: the wrapper falls
                    -- through to the real native target request so the player
                    -- answers the interaction themselves (design §6.1 "hand the
                    -- live interaction back if safely possible"; the engine
                    -- implementation is `targetGetForPlayer`'s exclusive target
                    -- mode, `GameTargeting.lua:299`). Every later prompt of this
                    -- invocation goes to the player too; the controller pauses
                    -- and the service releases the auto-combat lease.
                    if queue and command then command.target_sequence={} end
                    local function recordGeometry(typ)
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
                        if command and queue and #command.target_sequence<8 then
                            command.target_sequence[#command.target_sequence+1]={
                                shape=type(typ)=='table' and (type(typ.type)=='string' and typ.type or 'unknown') or nil,
                                range=type(typ)=='table' and finite(typ.range) and typ.range or nil,
                                radius=type(typ)=='table' and finite(typ.radius) and typ.radius or nil}
                        end
                    end
                    local function allowed(typ,x,y)
                        local map=g.level and g.level.map
                        if not map or not finite(x) or not finite(y) then return false,'invalid_target' end
                        if x<0 or y<0 or x>=map.w or y>=map.h then return false,'target_out_of_bounds' end
                        if type(typ)=='table' then
                            -- Preserve the native range guard. It is evaluated
                            -- against THIS request's own spec, so a value legal
                            -- for one prompt but not another stays refused.
                            if finite(typ.range) and finite(p.x) and finite(p.y)
                                and Distance.grid(p.x,p.y,x,y)>typ.range then return false,'target_out_of_range' end
                            -- Let the native UI raise its own self-target warning.
                            if x==p.x and y==p.y and typ.nowarning~=true and typ.talent~=nil then
                                return false,'self_target_warning'
                            end
                        end
                        return true
                    end
                    -- Record a typed queue deviation once. For a LIVE prompt the
                    -- caller hands the interaction back to the real native
                    -- targeting UI; for an already-settled flow (missing prompt
                    -- at return time) there is nothing to hand back and the
                    -- pause surfaces directly.
                    -- `extra.handback=true` marks a LIVE handback: the executor
                    -- records `command.target_handed_back` and must NOT set
                    -- `command.target_cancelled` (a still-live prompt is neither
                    -- answered nor cancelled). Every other deviation keeps the
                    -- existing cancel marker.
                    local function deviate(expectedIndex,expectedRequest,observedRequest,extra)
                        if command and not command.sequence_deviation then
                            local handback=false
                            local record={reason='unexpected_target_request',
                                expected={index=expectedIndex,request=expectedRequest},
                                observed={index=observed,request=observedRequest},
                                -- Only a missing trailing `optional` entry is
                                -- skippable; that case settles with `reduced=true`
                                -- instead of this deviation, so every emitted
                                -- deviation is a non-skippable mismatch.
                                skippable=false}
                            if extra then
                                for key,value in pairs(extra) do
                                    if key=='handback' then handback=value==true
                                    else record[key]=value end
                                end
                            end
                            if handback then record.handed_back=true end
                            command.sequence_deviation=assertDeviation(record)
                            if handback then
                                command.target_handed_back=record.reason
                            else
                                command.target_cancelled=command.target_cancelled or record.reason
                            end
                        end
                        return nil
                    end
                    -- Evaluate one declared entry's decided value at answer
                    -- time. An unevaluable value is the plugin's own
                    -- uncomputability boundary (`movement_request_value_unknown`),
                    -- never a wrong answer.
                    local function valueUnknown(index,request,dependency)
                        if command and not command.sequence_deviation then
                            command.sequence_deviation=assertDeviation({reason='movement_request_value_unknown',
                                expected={index=index,request=request},
                                observed={index=index,request=nil},
                                index=index,request=request,dependency=dependency,
                                skippable=false})
                            command.target_cancelled=command.target_cancelled or 'movement_request_value_unknown'
                        end
                        return nil
                    end
                    -- S2 rev3: the observed spec cannot be read as a signature
                    -- (`typ` not a table or `typ.type` not a string). The plugin
                    -- cannot prove what the native flow is asking, so it must
                    -- never answer blindly (design §6.1). This is a LIVE handback
                    -- (the prompt is still open): record
                    -- `command.target_handed_back`, never `target_cancelled`.
                    local function requestKindUnknown(index,request,shape)
                        if command and not command.sequence_deviation then
                            command.sequence_deviation=assertDeviation({reason='movement_request_kind_unknown',
                                expected={index=index,request=request},
                                observed={index=index,request=nil},
                                observed_shape=type(shape)=='string' and shape or nil,
                                handed_back=true,
                                skippable=false})
                            command.target_handed_back='movement_request_kind_unknown'
                        end
                        return nil
                    end
                    -- S2-REV-06: record the value actually answered for this
                    -- observed request (bounded: coordinates, the actor uid and
                    -- a short name), so the native evidence distinguishes the
                    -- per-prompt answers and not only their geometries.
                    local function recordAnswer(index,x,y,entity)
                        if command and command.target_sequence then
                            local entry=command.target_sequence[index]
                            if entry then
                                entry.answer={x=x,y=y,
                                    uid=(type(entity)=='table' and finite(entity.uid)) and entity.uid or nil,
                                    name=(type(entity)=='table' and type(entity.getName)=='function')
                                        and Details.text(entity:getName(),64) or nil}
                            end
                        end
                    end
                    local function resolveQueued()
                        local index=observed
                        local entry=queue[index]
                        local value=action.sequence[index]
                        if value==nil then return valueUnknown(index,entry.kind,'sequence_entry') end
                        -- Kind integrity (design §2.3/§4.4): the value we would
                        -- answer with must be admissible for the prompt kind this
                        -- position declares. This is the one non-inferential
                        -- kind check available (it never inspects the native
                        -- cursor spec); a real native reorder is not provable
                        -- here and surfaces as the native rejection or the
                        -- postcondition check instead.
                        if value.request~=nil and value.request~=entry.request then
                            return deviate(index,entry.request,value.request)
                        end
                        local valueKinds=SEQUENCE_VALUE_KINDS[entry.request]
                        if valueKinds==nil or not valueKinds[value.kind] then
                            return deviate(index,entry.request,value.kind)
                        end
                        if value.kind=='grid' then
                            if not finite(value.x) or not finite(value.y) then
                                return valueUnknown(index,entry.kind,'target_plan['..index..'].destination')
                            end
                            return value.x,value.y,nil
                        end
                        if value.kind=='self' then
                            if not (finite(p.x) and finite(p.y)) then
                                return valueUnknown(index,entry.kind,'self')
                            end
                            return p.x,p.y,p
                        end
                        if value.kind=='actor' then
                            local actor=target
                            if type(actor)~='table' or not finite(actor.x) or not finite(actor.y) then
                                return valueUnknown(index,entry.kind,'bound_actor')
                            end
                            return actor.x,actor.y,actor
                        end
                        return valueUnknown(index,entry.kind,'sequence_entry')
                    end
                    p.getTarget=function(self,typ,...)
                        recordGeometry(typ)
                        if consumed and not authoritative then return original(self,typ,...) end
                        if queue then
                            if yielded then
                                -- S2-REV-05: the queue already handed this live
                                -- interaction back to the player; it never
                                -- answers another prompt of this invocation.
                                return original(self,typ,...)
                            end
                            consumed=true
                            raised=true
                            observed=observed+1
                            local entry=queue[observed]
                            if entry==nil then
                                -- An extra prompt past the declared sequence:
                                -- record the shape the native flow actually
                                -- raised, then hand the live prompt back.
                                deviate(observed,nil,nil,
                                    {exhausted=true,count=#queue,
                                        observed_shape=observableSpec(typ) and typ.type or nil,
                                        handback=true})
                                yielded=true
                                return original(self,typ,...)
                            end
                            -- S2-R3-01 rev5: the normative runtime EXACTLY-ONE
                            -- gate. Compute the set of declared entries whose
                            -- curated observed signature matches this raised
                            -- prompt. The prompt may be answered ONLY when that
                            -- set is exactly the arrival position: zero matches
                            -- (extra/drifted prompt), several matches
                            -- (ambiguous declaration), or a match at another
                            -- index (reordered flow) are typed deviations — the
                            -- live prompt is handed back, never a blind answer
                            -- of the k-th declared value. Geometry alone is
                            -- never used as actor/grid evidence.
                            if not observableSpec(typ) then
                                requestKindUnknown(observed,entry.request,nil)
                                yielded=true
                                return original(self,typ,...)
                            end
                            local matched_indexes={}
                            for i=1,#queue do
                                if observedMatchesSignature(typ,queue[i],p) then
                                    matched_indexes[#matched_indexes+1]=i
                                end
                            end
                            if #matched_indexes~=1 or matched_indexes[1]~=observed then
                                deviate(observed,entry.request,nil,
                                    {observed_shape=typ.type,handback=true,
                                        matched_indexes=matched_indexes})
                                yielded=true
                                return original(self,typ,...)
                            end
                            local x,y,entity=resolveQueued()
                            if x==nil then
                                -- A decided value that cannot be evaluated is
                                -- the plugin's own uncomputability boundary: the
                                -- prompt is cancelled (there is no value to hand
                                -- the player either) and the typed pause below
                                -- releases control and the lease.
                                return nil
                            end
                            local ok,reason=allowed(typ,x,y)
                            if ok then
                                recordAnswer(observed,x,y,entity)
                                return x,y,entity
                            end
                            -- A value refused by this request's own native guard is
                            -- the existing native target-cancel path with its
                            -- typed reason (never a bypass).
                            if command then command.target_cancelled=reason end
                            return nil
                        end
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
                    -- Settle the queue on return: a missing non-optional entry is
                    -- a typed deviation (pauses, never resubmits); a missing
                    -- trailing `optional` entry is a settled native outcome
                    -- reported with `reduced=true`, not an error. A skipped
                    -- optional that was in fact raised leaves no marker.
                    -- S2 rev3: a deviation already recorded on a live prompt
                    -- (or a handed-back interaction) is authoritative — after a
                    -- handback the player owns the prompts, so the settle check
                    -- neither overwrites it nor reports the remaining entries as
                    -- missing.
                    -- S2-FIX5: the missing-entry rule applies only AFTER the
                    -- invocation actually entered the targeting flow (`raised`).
                    -- A native entry that refused before raising any prompt
                    -- (`useTalent` returned without ever calling getTarget —
                    -- cooldown / no energy / on_pre_use) has ZERO observed
                    -- prompts: there is no prompt to compare against the
                    -- declared sequence, so the ordinary native outcome
                    -- (`native_rejected` with its own detail, or the no-energy
                    -- classification) applies — never a fabricated
                    -- `unexpected_target_request`, never a `target_cancelled`.
                    -- S2-FIX5-R1: that exemption is NARROW — `raised` alone would
                    -- also excuse a FAILED-to-consume SUCCESS. It covers only a
                    -- pre-prompt native FAILURE (`preflightRefusal`, a falsy
                    -- return). A zero-prompt TRUTHY return for a declared
                    -- non-optional sequence means the curated prompts were never
                    -- consumed, so the missing-entry rule below still fires: the
                    -- action is NOT `action_complete` (the controller pauses on
                    -- the typed deviation instead of continuing with an
                    -- unconsumed ordered program). Fail-closed by default.
                    local preflightRefusal=not raised and not value
                    if queue and command and not command.sequence_deviation
                        and not yielded and not preflightRefusal then
                        local answeredSeq=observed
                        if answeredSeq<#queue then
                            local missing=queue[answeredSeq+1]
                            local optional=missing.optional==true
                            if optional then
                                command.sequence_reduced=true
                                command.sequence_reduced_reason='trailing_optional_not_raised'
                            else
                                command.sequence_deviation=assertDeviation({reason='unexpected_target_request',
                                    expected={index=answeredSeq+1,request=missing.request},
                                    observed={index=answeredSeq+1,request=nil},
                                    skippable=false})
                                command.target_cancelled=command.target_cancelled or 'unexpected_target_request'
                            end
                        end
                    end
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
    if not ok then
        local failure={ok=false,code='execution_error',energy_spent=spent,uncertain=true,
            native_message=tostring(ret)}
        -- A typed queue deviation is the more precise reason when the native body
        -- also raised: surface it (and its evidence) instead of masking it as a
        -- generic execution_error.
        if command and command.target_sequence then failure.target_sequence=command.target_sequence end
        if command and command.sequence_deviation then
            failure.sequence_deviation=command.sequence_deviation
            failure.code=command.sequence_deviation.reason
        end
        return failure
    end
    -- T_ATTACK returns true even when the underlying blow misses. A false
    -- talent result can spend energy during native pre-use failure; settle it.
    if command and command.invocation and command.invocation.pending>0 and not command.invocation.error then
        -- S2 rev3: the typed deviation must ride on the `native_pending` result
        -- itself (design §6.2), so the controller pauses on it BEFORE its
        -- `native_pending` branch and the service stops the run + revokes the
        -- lease inside this same submission. `handed_back=true` is evidence for
        -- the controller/policy log; the reason drives the pause.
        local pending={ok=true,code='native_pending',energy_spent=spent}
        if command.target_sequence then pending.target_sequence=command.target_sequence end
        if command.sequence_deviation then pending.sequence_deviation=command.sequence_deviation end
        if command.sequence_reduced then
            pending.reduced=true
            pending.reduced_reason=command.sequence_reduced_reason
        end
        if command.target_handed_back then pending.handed_back=true end
        return pending
    end
    local success = ret and true or false
    local result={ok=success,code=success and 'action_complete' or 'native_rejected',energy_spent=spent}
    if type(ret)=='boolean' then result.native_return=ret end
    -- An authoritative prefill that refused a genuinely invalid target request
    -- reports the typed guard reason instead of a generic native rejection.
    if command and command.target_cancelled and not success then
        result.code=command.target_cancelled
    end
    -- S2: surface the ordered-queue evidence and typed deviations through the
    -- already-declared command plumbing (no protocol/schema widening). A
    -- deviation always fails the action (it paused rather than answered a native
    -- request with a wrong value); a missing trailing `optional` entry is a
    -- settled native outcome reported with `reduced=true`.
    if command and command.target_sequence then result.target_sequence=command.target_sequence end
    if command and command.sequence_deviation then
        result.sequence_deviation=command.sequence_deviation
        result.ok=false
        result.code=command.sequence_deviation.reason
        result.uncertain=true
    end
    if command and command.target_handed_back then result.handed_back=true end
    if command and command.sequence_reduced then
        result.reduced=true
        result.reduced_reason=command.sequence_reduced_reason
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
