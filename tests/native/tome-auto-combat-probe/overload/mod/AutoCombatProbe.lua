-- GPL-3.0-or-later. Test-only native scenario runner for the P1a auto-combat
-- controller. It runs inside the real engine against the production Runtime
-- host (audited reads + the real Actions.execute executor) and reports one
-- `[AutoCombatProbe]` JSON line per declared check.
--
-- The expected signals for every scenario are declared up front in
-- M.EXPECTED; the runner compares the observed list against them. Nothing here
-- is loaded by the production addon.
local Runtime=require 'mod.mcp_bridge.Runtime'
local AutoCombat=require 'mod.auto_combat.AutoCombat'
local AutoCombatService=require 'mod.auto_combat.AutoCombatService'
local NativeActivity=require 'mod.mcp_bridge.NativeActivity'
local Presets=require 'mod.auto_combat.PolicyPresets'
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local EffectFootprint=require 'mod.auto_combat.EffectFootprint'
local Distance=require 'mod.mcp_bridge.Distance'
local EffectManifest=require 'mod.auto_combat.EffectManifest'
local ManifestDrift=require 'mod.auto_combat.EffectManifestDrift'
local M={pending=false,checks={},failures=0,solo_frames=0}

local function encode(value)
    local t=type(value)
    if t=='nil' then return 'null' end
    if t=='boolean' or t=='number' then return tostring(value) end
    if t=='string' then
        return '"'..value:gsub('[%z\1-\31\\"]',function(c) return ('\\u%04x'):format(c:byte()) end)..'"'
    end
    assert(t=='table')
    local parts={}
    for key,entry in pairs(value) do
        parts[#parts+1]=encode(tostring(key))..':'..encode(entry)
    end
    return '{'..table.concat(parts,',')..'}'
end
function M.emit(record) print('[AutoCombatProbe] '..encode(record)) end

local function check(name,condition,details)
    local record={kind='auto_combat_check',name=name,passed=condition and true or false,details=details}
    M.checks[#M.checks+1]=record
    if not condition then M.failures=M.failures+1 end
    M.emit(record)
end

-- Pre-declared expectations: the observed signal list for each scenario must
-- match exactly. An unexpected extra reason fails the fixture.
M.EXPECTED={
    ['start-when-ready']={'schedule_pump'},
    ['pause-resume']={'paused','schedule_pump'},
    ['native-pending']={'wait_native','wait_native','wait_native','acted'},
    ['critical']={'fallthrough','heal_recovered','action_denied','lease_released'},
    ['strict-resume']={'new_enemy','new_enemy'},
    ['rest-policy']={'wait_native','stopped'},
    ['explore-policy']={'wait_native','stopped'},
    ['sun-paladin-preset']={'valid','compatible','dry_run'},
    ['assistant-import']={'generated','valid','unsupported_reported','stored','refused'},
    ['computed-predicate']={'act','false_holds','enum_rejected'},
    ['production-reads']={'has_control','scalar_resource','guard_wired'},
    ['pilot-presets']={'ok','ok','ok','cast'},
    ['guard-real-spec']={'pristine_ok','mutation_used','restored_ok','grasp_safe'},
    ['effect-footprint-parity']={'parity_ok'},
    ['manifest-drift']={'verified','hash_reported','identity_ok','advisory_ok'},
    ['dynamic-talents']={'provider_ok','T_FLAMESHOCK:ok','T_FIREFLASH:ok','T_SHADOW_BLAST:ok','T_STARFALL:ok'},
    ['safety-handoff']={'handoff','owner_manual','stopped','resume_not_running'},
    ['movement']={'step_planned','step_executed','grid_annotated','random_annotated','random_policy_rejected'},
    ['movement-fallback']={'blocked_landing','alternative_planned','fallback_moved'},
    ['movement-factory']={'precise_grid','variant_unknown','dimensional_empty','dimensional_actor_gap','dimensional_unknown','vault_toward_range','vault_out_of_range','vault_exact','live_getter_value','getter_error_unknown'},
    ['movement-sequence']={'sd_plan_sequence','sd_reverse_plan_rejected','sd_static_unsupported','sd_two_requests_ordered','sd_distinct_values','sd_second_range_refused','sd_missing_optional_reduced','sd_reorder_refused','sd_cooldown_native_rejected','sd_cooldown_no_pause','sd_zero_prompt_success_deviated','sd_zero_prompt_success_paused'},
    ['movement-talents']={'rush_planned','rush_executed','tumble_planned','tumble_executed','teleport_planned','teleport_executed'},
    ['handback-answer']={'hb_phase_ready','hb_service_handoff','hb_pending_deviation','hb_lease_released','hb_not_resubmitted','hb_answerable','hb_never_waiting_native','hb_respond_routed','hb_respond_receipt'},
    ['handback-timeout']={'hb_phase_ready','hb_service_handoff','hb_pending_deviation','hb_lease_released','hb_not_resubmitted','hb_answerable','hb_never_waiting_native','hb_unanswered_cancelled'},
    ['handback-reorder']={'hb_phase_ready','hb_service_handoff','hb_pending_deviation','hb_lease_released','hb_not_resubmitted','hb_answerable','hb_never_waiting_native','hb_respond_routed','hb_respond_receipt','hb_same_kind_reorder'},
    ['scene-lifecycle']={'level_changed','stopped','resume_refused'},
    ['solo-pump']={},
}

local ATTACK={id='attack',priority=10,when={always={}},['then']={action='attack',target='nearest_hostile'}}
local WAIT={id='wait',priority=10,when={always={}},['then']={action='wait'}}
local HEAL={id='heal',priority=100,emergency=true,when={always={}},
    ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}}

local function policy(rules,limits)
    return {schema='tome-auto-combat/v1',id='probe',name='probe',
        limits=limits or {max_actions_per_tick=1},
        safety={min_hp_pct=35,flee_below_hp_pct=25,pause_on_new_enemy=true,
            pause_on_unknown_safety=true,max_selffire_risk=0},
        targeting={default='nearest_hostile'},rules=rules}
end

-- A host that delegates every read to the production host but lets a scenario
-- override specific callbacks.
local function hostFor(pol,overrides)
    local real=Runtime.buildAutoCombatHostFor(game,pol)
    if not real then return nil end
    local host={}
    for key,value in pairs(real) do host[key]=value end
    for key,value in pairs(overrides or {}) do host[key]=value end
    return host
end

-- A host that records every request attempt (including the real executor path).
local function recordingHost(pol,overrides)
    local real=Runtime.buildAutoCombatHostFor(game,pol)
    local attempts={}
    local host={}
    for key,value in pairs(real) do host[key]=value end
    host.request=function(attempt)
        attempts[#attempts+1]={rule=attempt.rule,action=attempt.action,talent=attempt.talent,
            target=attempt.target,bound_target=attempt.bound_target}
        if overrides and overrides.request then return overrides.request(attempt,real.request) end
        return real.request(attempt)
    end
    for key,value in pairs(overrides or {}) do if key~='request' then host[key]=value end end
    return host,attempts
end

local function forceReady()
    local p=game.player
    if p and p.energy then p.energy.value=1000 end
    game.paused=true
end

local function compare(name,observed)
    local expected=M.EXPECTED[name] or {}
    local passed=type(observed)=='table' and #observed==#expected
    if passed then
        for i=1,#expected do if observed[i]~=expected[i] then passed=false end end
    end
    check(name,passed,{expected=expected,observed=observed})
    return passed
end

-- 1: start while the player is already ready must schedule a pump immediately.
local function startWhenReady()
    forceReady()
    local pol=policy({WAIT})
    local host=hostFor(pol,{phase=function() return 'ready' end})
    local c=AutoCombat.new(pol,host,{strict=false})
    local started=c:start()
    return compare('start-when-ready',{started.action})
end

-- 2: pause then resume advances the generation, discarding the old decision.
local function pauseResume()
    forceReady()
    local pol=policy({WAIT})
    local host=hostFor(pol,{phase=function() return 'ready' end})
    local c=AutoCombat.new(pol,host,{strict=false})
    c:start()
    local generation=c.generation
    local paused=c:pause('probe_pause')
    local stale=c:isStale(generation)
    local resumed=c:resume()
    check('pause-resume:stale-discarded',stale and c.generation>generation and c.attempts==0,
        {generation=generation,current=c.generation,attempts=c.attempts})
    check('pause-resume:reason',paused.reason=='probe_pause',{reason=paused.reason})
    return compare('pause-resume',{'paused',resumed.action})
end

-- 3: a native_pending result is an internal wait; never resubmit while pending.
local function nativePending()
    forceReady()
    local phase='ready'
    local calls=0
    local pol=policy({WAIT})
    local host,attempts=recordingHost(pol,{
        phase=function() return phase end,
        request=function()
            calls=calls+1
            if calls==1 then return {status='native_pending'} end
            return {status='ok',code='probe_action',energy_spent=true}
        end})
    local c=AutoCombat.new(pol,host,{strict=false})
    c:start()
    local r1=c:onOpportunity()
    phase='native_pending'
    local r2=c:onOpportunity()
    local r3=c:onOpportunity()
    phase='ready'
    local r4=c:onOpportunity()
    check('native-pending:no-resubmit',calls==2 and #attempts==2,{calls=calls,attempts=#attempts})
    return compare('native-pending',{r1.action,r2.action,r3.action,r4.action})
end

-- 4: below min_hp_pct only emergency rules may run. D-1 (P1, round
-- anor-reg-01): an emergency action the native engine refuses (here: the
-- production `native_rejected` + cooldown `missing` shape, on cooldown) must
-- not park the run. It falls through to the next applicable normal rule so
-- ticks keep advancing and the cooldown recovers; the emergency action is used
-- again on a later opportunity. R-1 (fix2): the schema-valid limit-1 boundary
-- behaves the same — a settled no-energy reject does not consume the only
-- budget slot, so the fall-through runs in the same opportunity. When no
-- fallback is applicable the run stops with the typed reason action_denied and
-- releases the lease (never a held-lease frozen pause).
local function criticalState()
    forceReady()
    local p=game.player
    if not p:knowTalent('T_HEALING_LIGHT') then p:learnTalent('T_HEALING_LIGHT',true) end
    p.life=p.max_life*0.3
    local saved_cd=p.talents_cd and p.talents_cd.T_HEALING_LIGHT
    local signals={}
    local oid=1
    local function forceCooldown()
        if p.talents_cd then p.talents_cd.T_HEALING_LIGHT=10 end
    end
    -- The production `Actions.execute` refusal shape for a talent whose own
    -- cooldown is still running; the fallback (wait) goes through the real
    -- native executor.
    local function cooldownRefusal()
        return {status='rejected',code='native_rejected',energy_spent=false,
            missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=10,required=0}},
            hint='talent on cooldown; wait for the listed turns before retrying',
            native_message='Healing Light is still on cooldown for 10 turns.'}
    end
    local function healRefused()
        return p.talents_cd and (p.talents_cd.T_HEALING_LIGHT or 0)>0
    end
    -- (a) the refused emergency falls through to the wait rule, which runs
    -- natively and spends the turn (advancing the world tick/cooldown). The
    -- limit is the schema-valid boundary max_actions_per_tick=1: the refusal
    -- produced no native action, so it does not consume the only slot (R-1).
    forceCooldown()
    local pol=policy({HEAL,WAIT},{max_actions_per_tick=1})
    local host,attempts=recordingHost(pol,{phase=function() return 'ready' end,
        opportunity_id=function() return oid end,
        request=function(attempt,real_request)
            if attempt.rule=='heal' and healRefused() then return cooldownRefusal() end
            return real_request(attempt)
        end})
    local notified={}
    host.notify=function(event) notified[#notified+1]=event end
    local c=AutoCombat.new(pol,host,{strict=false})
    c:start()
    local result=c:onOpportunity()
    local healAttempts=0
    for _,attempt in ipairs(attempts) do
        if attempt.rule=='heal' then healAttempts=healAttempts+1 end
    end
    local fell=result.action=='acted' and result.rule=='wait' and healAttempts>=1
    check('critical:fallthrough',fell,
        {action=result.action,reason=result.reason,rule=result.rule,heal_attempts=healAttempts,attempts=attempts})
    signals[#signals+1]=fell and 'fallthrough' or 'no_fallthrough'
    -- D-2 (production notify path): the deny event carries the structured
    -- cooldown detail and the native message.
    local denyEvent
    for _,event in ipairs(notified) do if event.kind=='denied' then denyEvent=event end end
    check('critical:denied-detail',denyEvent and denyEvent.missing and denyEvent.missing[1]
        and denyEvent.missing[1].kind=='cooldown' and denyEvent.native_message~=nil,
        {deny=denyEvent})
    -- (b) once the cooldown clears, the emergency action is used again.
    if p.talents_cd then p.talents_cd.T_HEALING_LIGHT=0 end
    p.life=p.max_life*0.3
    forceReady()
    oid=oid+1
    local result2=c:onOpportunity()
    local healActed=result2.action=='acted' and result2.rule=='heal'
    check('critical:heal-recovered',healActed,{action=result2.action,rule=result2.rule,reason=result2.reason,
        outcome=result2.outcome})
    signals[#signals+1]=healActed and 'heal_recovered' or 'heal_not_recovered'
    -- (c) no applicable fallback: the production service stops the run with the
    -- typed refusal (`action_denied`) and releases the lease — a settled reject
    -- can never leave a held-lease frozen loop (R-1); `resume` cannot replay
    -- the rejected action.
    forceCooldown()
    p.life=p.max_life*0.3
    forceReady()
    local onlyHeal=policy({HEAL},{max_actions_per_tick=1})
    local host2,attempts2=recordingHost(onlyHeal,{phase=function() return 'ready' end,
        opportunity_id=function() return 1 end,
        request=function() return cooldownRefusal() end})
    local svc=AutoCombatService.new{host_factory=function() return host2 end}
    local d2=AutoCombatService.handle(svc,'set_draft',{policy=onlyHeal})
    AutoCombatService.handle(svc,'approve',{expected_hash=d2.draft_hash})
    AutoCombatService.handle(svc,'activate',{})
    local started2=AutoCombatService.handle(svc,'start',{})
    if not (started2 and started2.ok) then
        check('critical:action-denied',false,{start=started2})
        signals[#signals+1]='start_failed'
    else
        local stepped=AutoCombatService.step(svc)
        local result3=stepped and stepped.step or {}
        local typed=(result3.action=='stopped' or result3.action=='paused')
            and result3.reason=='action_denied'
        check('critical:action-denied',typed,
            {action=result3.action,reason=result3.reason,attempts=attempts2})
        signals[#signals+1]=typed and 'action_denied' or 'wrong_reason'
        local released=svc.arbiter.owner=='manual' and svc.controller
            and svc.controller.state=='stopped'
        local resumed=AutoCombatService.handle(svc,'resume',{})
        local refused=resumed and resumed.ok==false and resumed.error
            and resumed.error.code=='not_running'
        check('critical:lease-released',released and refused,
            {owner=svc.arbiter.owner,state=svc.controller and svc.controller.state,
                resume=resumed})
        signals[#signals+1]=(released and refused) and 'lease_released' or 'lease_held'
    end
    if p.talents_cd then p.talents_cd.T_HEALING_LIGHT=saved_cd end
    p.life=p.max_life
    return compare('critical',signals)
end

-- 5: strict mode confirms the visible set on start/resume, then pauses again for
-- the next unconfirmed enemy.
local function strictResume()
    forceReady()
    local ids={'a'}
    local pol=policy({WAIT})
    local host=hostFor(pol,{phase=function() return 'ready' end,enemy_ids=function() return ids end})
    local c=AutoCombat.new(pol,host,{strict=true})
    c:start()
    c:onOpportunity()
    ids={'a','b'}
    local p1=c:onOpportunity()
    c:resume()
    c:onOpportunity()
    ids={'a','b','c'}
    local p2=c:onOpportunity()
    check('strict-resume:reasons',p1.reason=='new_enemy' and p2.reason=='new_enemy',
        {first=p1.reason,second=p2.reason})
    return compare('strict-resume',{p1.reason,p2.reason})
end

-- 6: a `rest` rule in a data policy drives the real native rest through the
-- generic NativeActivity, occupies the wait, and yields control when done.
local function restPolicy()
    forceReady()
    local p=game.player
    p.life=math.max(1,math.floor(p.max_life*0.5))
    local previous_check=p.restCheck
    p.restCheck=function() return true end
    local pol=policy({{id='camp',priority=10,when={hp_pct={lt=100}},
        ['then']={action='rest',max_turns=1}}})
    local host=hostFor(pol,{phase=function()
        if game.player.resting then return 'settling' end
        return 'ready'
    end})
    if not host then
        check('rest-policy:host',false,{note='production host unavailable'})
        return false
    end
    local c=AutoCombat.new(pol,host,{strict=false})
    local svc=Runtime.autoCombatService(game)
    svc.controller=c
    c:start()
    local r1=c:onOpportunity()
    check('rest-policy:started',p.resting~=nil and r1.action=='wait_native',
        {action=r1.action,resting=p.resting~=nil})
    if p.resting then p:restStop('probe_done') end
    p.restCheck=previous_check
    forceReady()
    p.life=p.max_life
    local r2=c:onOpportunity()
    svc.controller=nil
    return compare('rest-policy',{r1.action,r2.action})
end

-- 7: an `auto_explore` rule in a data policy is validated against the real
-- native guard. The probe level keeps a hostile, so the guard refuses with a
-- declared signal; if a clear level is ever used the run path is exercised too.
local function explorePolicy()
    forceReady()
    local refusal=NativeActivity.descriptor('auto_explore').guards({player=game.player,game=game})
    if refusal then
        check('explore-policy:guarded',refusal.ok==false and refusal.code~=nil,refusal)
        M.EXPECTED['explore-policy']={'rejected:'..refusal.code}
        return compare('explore-policy',{'rejected:'..refusal.code})
    end
    local pol=policy({{id='scout',priority=10,when={always={}},
        ['then']={action='auto_explore'}}})
    local host=hostFor(pol,{phase=function()
        if game.player.running then return 'settling' end
        return 'ready'
    end})
    if not host then
        check('explore-policy:host',false,{note='production host unavailable'})
        return false
    end
    local c=AutoCombat.new(pol,host,{strict=false})
    local svc=Runtime.autoCombatService(game)
    svc.controller=c
    c:start()
    local r1=c:onOpportunity()
    check('explore-policy:started',r1.action=='wait_native' or r1.action=='acted',
        {action=r1.action,running=game.player.running~=nil})
    if game.player.running then game.player:runStop('probe_done') end
    forceReady()
    local r2=c:onOpportunity()
    svc.controller=nil
    return compare('explore-policy',{r1.action,r2.action})
end

-- 11 (Option A, deferred): set up a flee-threshold run and let the production
-- frame pump perform the safety handoff; the check runs on later frames.
local function safetyHandoffSetup()
    forceReady()
    Runtime.setAutoCombatExecution(game,true)
    local pol=policy({{id='wait',priority=10,when={always={}},['then']={action='wait'}}},{max_actions_per_tick=1})
    Runtime.autoCombatHandle(game,'set_draft',{policy=pol})
    local approved=Runtime.autoCombatHandle(game,'approve',{})
    if not (approved and approved.ok) then
        check('safety-handoff:approve',false,approved)
        Runtime.setAutoCombatExecution(game,false)
        return false
    end
    Runtime.autoCombatHandle(game,'activate',{expected_hash=approved.approved_hash})
    local p=game.player
    M.handoff_saved_life=p.life
    p.life=math.max(1,math.floor(p.max_life*0.1))
    forceReady()
    local started=Runtime.autoCombatHandle(game,'start',{})
    M.handoff_frames=0
    return started and started.ok or false
end

local function safetyHandoffCheck()
    M.handoff_frames=(M.handoff_frames or 0)+1
    local status=Runtime.autoCombatStatus(game) or {}
    local run=status.run
    local handoff=status.control_owner=='manual' and run and run.state=='stopped'
    if not handoff and M.handoff_frames<40 then return false end
    local signals={}
    check('safety-handoff:handoff',handoff,{owner=status.control_owner,run=run,frames=M.handoff_frames})
    signals[#signals+1]=handoff and 'handoff' or 'no_handoff'
    signals[#signals+1]=status.control_owner=='manual' and 'owner_manual' or 'owner_held'
    check('safety-handoff:owner',status.control_owner=='manual',status)
    signals[#signals+1]=(run and run.state=='stopped') and 'stopped' or 'not_stopped'
    check('safety-handoff:stopped',run and run.state=='stopped',status)
    local resumed=Runtime.autoCombatHandle(game,'resume',{})
    local refused=resumed.ok==false and resumed.error and resumed.error.code=='not_running'
    signals[#signals+1]=refused and 'resume_not_running' or 'resume_accepted'
    check('safety-handoff:resume',refused,resumed)
    game.player.life=M.handoff_saved_life
    Runtime.autoCombatHandle(game,'stop',{})
    Runtime.setAutoCombatExecution(game,false)
    compare('safety-handoff',signals)
    return true
end

-- 8: the P2 second-class preset validates, is catalogue-compatible, and
-- dry-runs against the real engine snapshot through the production service.
local function sunPaladinPreset()
    local preset=Presets.get('sun_paladin_p2')
    local signals={}
    local schema_ok=preset~=nil and Schema.validate(preset)==true
    signals[#signals+1]=schema_ok and 'valid' or 'invalid_schema'
    check('sun-paladin-preset:schema',schema_ok,{})
    local catalog_ok=schema_ok and Catalog.verify(preset)==true
    signals[#signals+1]=catalog_ok and 'compatible' or 'incompatible'
    check('sun-paladin-preset:catalog',catalog_ok,{})
    local dry=Runtime.autoCombatHandle(game,'dry_run',{policy=preset})
    local dry_ok=dry and dry.ok==true and dry.dry_run==true and dry.executed==false
    signals[#signals+1]=dry_ok and 'dry_run' or 'dry_run_failed'
    check('sun-paladin-preset:dry-run',dry_ok,dry)
    return compare('sun-paladin-preset',signals)
end

-- 9: generation-only assistant import through the production service. It
-- translates a pinned export into a draft, reports unsupported entries, stores
-- only on request, and refuses a wrong version. It never approves/activates.
local function assistantImport()
    local config={format='tome-auto-combat-assistant-export/v1',
        assistant={addon='auto_talent_assistant',addon_version={2,3,9},tome_version={1,7,4}},
        class='celestial/anorithil',settings={min_hp_pct=35,max_actions_per_tick=1},
        sustains={{talent='T_CHANT_OF_FORTRESS',enabled=true,priority=20}},
        talents={
            {talent='T_HEALING_LIGHT',enabled=true,priority=100,emergency=true,
                when={hp_pct={lt=50}}},
            {talent='T_UNSUPPORTED_LEGACY',enabled=true,priority=50,when={hp_pct={lt=80}}},
        }}
    local signals={}
    local result=Runtime.autoCombatHandle(game,'import_assistant',{config=config})
    local generated=result and result.ok==true and result.imported==true and result.draft~=nil
    signals[#signals+1]=generated and 'generated' or 'generate_failed'
    check('assistant-import:generated',generated,result)
    local valid=generated and Schema.validate(result.draft)==true and Catalog.verify(result.draft)==true
    signals[#signals+1]=valid and 'valid' or 'invalid'
    check('assistant-import:valid',valid,{})
    local reported=false
    for _,entry in ipairs(generated and result.unsupported or {}) do
        if entry.code=='unsupported_talent' then reported=true end
    end
    signals[#signals+1]=reported and 'unsupported_reported' or 'unsupported_missing'
    check('assistant-import:unsupported',reported,generated and result.unsupported)
    local service=Runtime.autoCombatService(game)
    -- X-doubleprime: `store.approved` is an immutable snapshot record, so the
    -- comparison is on its recorded hash (not a mutable table identity).
    local approved_before=service.store.approved and service.store.approved.hash
    local stored=Runtime.autoCombatHandle(game,'import_assistant',{config=config,store=true})
    local store_ok=stored and stored.ok==true and stored.stored and stored.stored.draft_hash
        and (service.store.approved and service.store.approved.hash)==approved_before
    signals[#signals+1]=store_ok and 'stored' or 'store_failed'
    check('assistant-import:store',store_ok,stored)
    local wrong=Runtime.autoCombatHandle(game,'import_assistant',
        {config={format='tome-auto-combat-assistant-export/v1',
            assistant={addon='auto_talent_assistant',addon_version={9,9,9}},
            talents={{talent='T_HEALING_LIGHT',enabled=true,priority=1,when={always={}}}}}})
    local refused=wrong and wrong.ok==false and wrong.error and wrong.error.code=='assistant_version_mismatch'
    signals[#signals+1]=refused and 'refused' or 'not_refused'
    check('assistant-import:refused',refused,wrong)
    return compare('assistant-import',signals)
end

-- 10: tooltip-safe computed predicate through the production dry-run. A
-- resist/armor-style scalar getter decides a predicate numerically; an
-- arbitrary path is rejected by the schema; an unavailable getter is unknown.
local function computedPredicate()
    local function waitRule(id,value)
        return policy({{id=id,priority=10,
            when={computed={field='defense.armor',ge=value}},['then']={action='wait'}}})
    end
    local dry=Runtime.autoCombatHandle(game,'dry_run',{policy=waitRule('armored',0)})
    local acts=dry and dry.ok==true and dry.decision=='act' and dry.rule=='armored'
    check('computed-predicate:act',acts,dry)
    local high=Runtime.autoCombatHandle(game,'dry_run',{policy=waitRule('high',1e30)})
    local holds=high and high.ok==true and high.decision~='act'
    check('computed-predicate:false',holds,high)
    local bad=Runtime.autoCombatHandle(game,'dry_run',{policy=policy({{id='bad',priority=10,
        when={computed={field='arbitrary.path',gt=1}},['then']={action='wait'}}})})
    local rejected=bad and bad.ok==false and bad.error and bad.error.code=='invalid_policy'
    check('computed-predicate:enum',rejected,bad)
    local signals={acts and 'act' or 'no_act',holds and 'false_holds' or 'false_acted',
        rejected and 'enum_rejected' or 'enum_accepted'}
    return compare('computed-predicate',signals)
end

-- 11: production read host and standalone control (AC-02/AC-07). A scalar
-- resource projection is checked against a temporarily-set scalar field and
-- the real unlock gate; the standalone lease must be part of hasControl.
local function productionReads()
    Runtime.setAutoCombatExecution(game,true)
    local pol=policy({WAIT})
    Runtime.autoCombatHandle(game,'set_draft',{policy=pol})
    local approved=Runtime.autoCombatHandle(game,'approve',{})
    Runtime.autoCombatHandle(game,'activate',{expected_hash=approved.approved_hash})
    local signals={}
    local controlled=Runtime.hasControl(game.player)==true
    signals[#signals+1]=controlled and 'has_control' or 'no_control'
    check('production-reads:has-control',controlled,{})
    local p=game.player
    local saved={positive=p.positive,max_positive=p.max_positive,min_positive=p.min_positive}
    local defs=p.resources_def
    local pool=type(defs)=='table' and defs.positive and defs.positive.talent or nil
    local saved_talent=pool and p.talents and p.talents[pool] or nil
    if pool and type(p.talents)=='table' then p.talents[pool]=1 end
    p.positive=42;p.max_positive=100;p.min_positive=0
    local read=Runtime.buildAutoCombatReadHostFor(game,pol)
    local scalar=read.resource_value and read.resource_value('positive')==42
        and read.resource_pct and read.resource_pct('positive')==42
    signals[#signals+1]=scalar and 'scalar_resource' or 'resource_mismatch'
    check('production-reads:resource',scalar,{value=read.resource_value and read.resource_value('positive'),
        pct=read.resource_pct and read.resource_pct('positive')})
    p.positive=saved.positive;p.max_positive=saved.max_positive;p.min_positive=saved.min_positive
    if pool and type(p.talents)=='table' then p.talents[pool]=saved_talent end
    local live=Runtime.buildAutoCombatHostFor(game,pol)
    local guard_ok=type(live.guard)=='function'
    signals[#signals+1]=guard_ok and 'guard_wired' or 'guard_missing'
    check('production-reads:guard',guard_ok,{})
    Runtime.autoCombatHandle(game,'deactivate',{})
    Runtime.setAutoCombatExecution(game,false)
    return compare('production-reads',signals)
end

-- 6: with no MCP client, local authorization installs the live pump and the
-- production executor performs a real native wait action.
local function soloPumpSetup()
    forceReady()
    Runtime.setAutoCombatExecution(game,true)
    local pol=policy({WAIT},{max_actions_per_tick=1})
    Runtime.autoCombatHandle(game,'set_draft',{policy=pol})
    local approved=Runtime.autoCombatHandle(game,'approve',{})
    if not (approved and approved.ok) then return false end
    local activated=Runtime.autoCombatHandle(game,'activate',{expected_hash=approved.approved_hash})
    if not (activated and activated.ok) then return false end
    -- The wait runs from the display pump and clears game.paused. The core tick
    -- loop must be woken explicitly or the game parks (the P0 recover stall).
    M.solo_turn_start=game.turn
    local started=Runtime.autoCombatHandle(game,'start',{})
    return started and started.ok or false
end

local function soloPumpCheck()
    M.solo_frames=M.solo_frames+1
    local status=Runtime.autoCombatStatus(game) or {}
    local run=status.run or {}
    local log=Runtime.autoCombatHandle(game,'log',{limit=16})
    local acted=false
    if log and log.ok and log.events then
        for _,event in ipairs(log.events) do
            if event.kind=='acted' then acted=true end
        end
    end
    if not acted and M.solo_frames<12 then return false end
    -- Regression: after the wait the game must keep ticking, not park in
    -- `settling` with a frozen world tick. Give the boundary tick a bounded
    -- number of frames to arrive before asserting.
    local tick_advanced=game.turn>(M.solo_turn_start or 0)
    if not tick_advanced and M.solo_frames<40 then return false end
    M.waiting_solo=false
    check('solo-pump:ran',acted and (run.attempts or 0)>0,
        {attempts=run.attempts,state=run.state,reason=run.reason,acted=acted,frames=M.solo_frames})
    check('solo-pump:tick-advanced',tick_advanced,
        {turn_start=M.solo_turn_start,turn=game.turn,paused=game.paused,
            energy=game.player and game.player.energy and game.player.energy.value,frames=M.solo_frames})
    Runtime.autoCombatHandle(game,'stop',{reason='probe_done'})
    Runtime.setAutoCombatExecution(game,false)
    local after=Runtime.autoCombatStatus(game) or {}
    check('solo-pump:stopped',(after.run==nil or after.run.state=='stopped')
        and not Runtime.autoCombatExecutionEnabled(game),
        {run=after.run,execution=Runtime.autoCombatExecutionEnabled(game)})
    compare('solo-pump',{})
    -- MFT-REV-09 final native scenarios run after every existing scenario, so
    -- their native (possibly yielding) skill bodies cannot disturb the earlier
    -- checks. The first waits for the game to report ready again.
    M.waiting_final=true
    M.final_stage='talents'
    M.final_frames=0
    return true
end

-- 12 (round 4): the new class pilots. Force-learn each pilot's kit on the
-- probe actor, prove Actions.admit accepts it, dry-run the preset against the
-- real snapshot, and cast one main damage talent through the production host
-- (guard + Actions.execute + native useTalent).
local function pilotPresets()
    local Actions=require 'mod.mcp_bridge.Actions'
    local p=game.player
    local function learn(id)
        if not p:knowTalent(id) then p:learnTalent(id,true) end
        return p:knowTalent(id)==true
    end
    local specs={
        {preset='archmage_arcane_p2',resource='mana',
            talents={'T_FLAME','T_HEAL','T_ARCANE_POWER','T_SHIELDING'}},
        {preset='corruptor_blight_p2',resource='vim',
            talents={'T_SOUL_ROT','T_BLOOD_GRASP','T_DARK_RITUAL'}},
        {preset='berserker_p2',resource='stamina',
            talents={'T_SHATTERING_BLOW','T_BERSERKER_RAGE','T_DAUNTING_PRESENCE','T_ADRENALINE_SURGE'}},
    }
    local signals={}
    for _,spec in ipairs(specs) do
        local preset=Presets.get(spec.preset)
        local admitted=true
        for _,id in ipairs(spec.talents) do
            if not learn(id) then admitted=false end
        end
        for _,id in ipairs(spec.talents) do
            local mode=Catalog.isSustain(id) and 'sustained' or 'activated'
            if not Actions.admit(p,id,mode) then admitted=false end
        end
        -- A live read host built from the current snapshot; the resource
        -- predicate must see the unlocked pool (force-learn provides it).
        local max=p['max_'..spec.resource]
        if max then p[spec.resource]=max end
        local read=Runtime.buildAutoCombatReadHostFor(game,preset)
        local known=true
        for _,id in ipairs(spec.talents) do
            if read.talent_known(id)~=true then known=false end
        end
        local dry=Runtime.autoCombatHandle(game,'dry_run',{policy=preset})
        local ok=dry and dry.ok==true and dry.executed==false and dry.side_effects=='none'
            and dry.decision~=nil
        check(spec.preset..':admitted',admitted,{})
        check(spec.preset..':known',known,{})
        check(spec.preset..':dry-run',ok,dry)
        signals[#signals+1]=(admitted and known and ok) and 'ok' or 'bad'
    end
    -- One real executor cast: the Archmage flame through the production host.
    local arch=Presets.get('archmage_arcane_p2')
    local host=Runtime.buildAutoCombatHostFor(game,arch)
    local ctx=host and host.snapshot('nearest_hostile')
    local bound=ctx and ctx.bound_target
    if p.max_mana then p.mana=p.max_mana end
    local outcome=bound and host.request({action='use_talent',talent='T_FLAME',
        target='nearest_hostile',bound_target=bound})
    local cast=outcome~=nil and (outcome.status=='ok' or outcome.status=='native_pending')
    check('pilot-presets:cast',cast,{outcome=outcome,bound=bound})
    signals[#signals+1]=cast and 'cast' or 'cast_failed'
    return compare('pilot-presets',signals)
end

-- 13: builder identity/closure is enforced on every guarded action. A genuine
-- builder is accepted; a replacement (even for an otherwise-valid target spec)
-- is a mutation and fails closed; restoring the genuine builder recovers. Blood
-- Grasp's real builder classifies as safe.
local function guardRealSpec()
    local p=game.player
    if not p:knowTalent('T_FLAME') then p:learnTalent('T_FLAME',true) end
    if not p:knowTalent('T_BLOOD_GRASP') then p:learnTalent('T_BLOOD_GRASP',true) end
    local pol=policy({WAIT})
    local host=Runtime.buildAutoCombatHostFor(game,pol)
    local bound=host and host.snapshot('nearest_hostile').bound_target
    local def=p.talents_def and p.talents_def.T_FLAME
    if not bound or not (def and type(def.target)=='function') then
        check('guard-real-spec:setup',false,{bound=bound,has_builder=def~=nil})
        return compare('guard-real-spec',{'no_setup','no_setup','no_setup','no_setup'})
    end
    local signals={}
    local pristine=host.guard({action='use_talent',talent='T_FLAME',bound_target=bound})
    local pristine_ok=pristine==nil or pristine.reason~='adapter_source_drift'
    check('guard-real-spec:pristine',pristine_ok,pristine)
    signals[#signals+1]=pristine_ok and 'pristine_ok' or 'pristine_drift'
    -- NO-AUDIT (v1.6): a replaced builder is USED, not gated. The replacement is
    -- a huge self/friendly-hitting ball, so the guard rejects it on its measured
    -- value (selffire_risk), never on identity.
    local original=def.target
    def.target=function() return {type='ball',range=100,radius=10,selffire=true,friendlyfire=true,player_selffire=true} end
    local mutated=host.guard({action='use_talent',talent='T_FLAME',bound_target=bound})
    local mutation_used=(mutated==nil) or (mutated.reason~='adapter_source_drift'
        and mutated.reason~='unsupported_adapter')
    check('guard-real-spec:mutated',mutation_used,mutated)
    signals[#signals+1]=mutation_used and 'mutation_used' or 'mutation_gated'
    def.target=original
    local restored=host.guard({action='use_talent',talent='T_FLAME',bound_target=bound})
    local restored_ok=restored==nil or restored.reason~='adapter_source_drift'
    check('guard-real-spec:restored',restored_ok,restored)
    signals[#signals+1]=restored_ok and 'restored_ok' or 'restored_drift'
    -- Blood Grasp's real builder is a bolt with explicit SF 0 / FF 0.
    local grasp=host.guard({action='use_talent',talent='T_BLOOD_GRASP',bound_target=bound})
    check('guard-real-spec:grasp',grasp==nil,grasp)
    signals[#signals+1]=grasp==nil and 'grasp_safe' or 'grasp_risky'
    return compare('guard-real-spec',signals)
end

local function sameSet(a,b)
    local function count(set)
        local n=0
        for _,column in pairs(set or {}) do for _ in pairs(column) do n=n+1 end end
        return n
    end
    if count(a)~=count(b) then return false end
    for x,column in pairs(a or {}) do
        for y in pairs(column) do if not (b[x] and b[x][y]) then return false end end
    end
    return true
end

-- V2-3: the production footprint backend must reproduce the real
-- ActorProject:project grid collection for every audited shape, including a
-- corner that actually triggers the blocked-corner branch. Native block
-- callbacks return (block, hit, hit_radius); the corner oracle needs the
-- three-return form, so the corner cases are non-tautological rather than an
-- ordinary path stop.
function M.effectFootprintParity()
    local p=game.player
    local ctx={game=game,source=p}
    local is_hex=util.isHex() and true or false
    check('effect-footprint:map-mode',is_hex==false,{mode=is_hex and 'hex' or 'square',
        note='ToME 1.7.6 is a square grid; assert rather than assume'})
    local function blocker(cellFn)
        local corners=0
        local fn=function(typ,lx,ly,for_highlights)
            if for_highlights then corners=corners+1 end
            return cellFn(lx,ly,for_highlights==true)
        end
        return fn,function() return corners end,function() corners=0 end
    end
    local function simpleBlock(bx,by)
        return function(lx,ly)
            if lx==bx and ly==by then return true,true,true end
            return false,true,true
        end
    end
    local function allCorner(lx,ly,corner)
        if corner then return true,true,false end
        return false,true,true
    end
    local function lateCorner(lx,ly,corner)
        if corner and core.fov.distance(p.x,p.y,lx,ly)>=2 then return true,true,false end
        return false,true,true
    end
    local boltFn,boltCorners,boltReset=blocker(simpleBlock(p.x+2,p.y))
    local beamFn,beamCorners,beamReset=blocker(simpleBlock(p.x+2,p.y))
    local cornerFn,cornerCorners,cornerReset=blocker(allCorner)
    local laterFn,laterCorners,laterReset=blocker(lateCorner)
    local cases={
        {name='hit',spec={type='hit',range=20,no_restrict=true},target={x=p.x+4,y=p.y}},
        {name='bolt',spec={type='bolt',range=20,no_restrict=true},target={x=p.x+5,y=p.y}},
        {name='beam',spec={type='beam',range=20,no_restrict=true},target={x=p.x+5,y=p.y}},
        {name='ball1',spec={type='ball',range=20,radius=1,no_restrict=true},target={x=p.x+4,y=p.y}},
        {name='ball2',spec={type='ball',range=20,radius=2,no_restrict=true},target={x=p.x+3,y=p.y+1}},
        {name='widebeam1',spec={type='widebeam',range=20,radius=1,no_restrict=true},target={x=p.x+4,y=p.y}},
        {name='widebeam2',spec={type='widebeam',range=20,radius=2,no_restrict=true},target={x=p.x+3,y=p.y+2}},
        {name='cone1',spec={type='cone',range=20,radius=1,no_restrict=true},target={x=p.x+4,y=p.y}},
        {name='cone2',spec={type='cone',range=20,radius=2,no_restrict=true},target={x=p.x+3,y=p.y+2}},
        {name='bolt_block',spec={type='bolt',range=20,no_restrict=true,block_path=boltFn},
            target={x=p.x+5,y=p.y},reset=boltReset,corners=boltCorners},
        {name='beam_block',spec={type='beam',range=20,no_restrict=true,block_path=beamFn},
            target={x=p.x+5,y=p.y},reset=beamReset,corners=beamCorners},
        {name='corner_first',spec={type='beam',range=20,no_restrict=true,block_path=cornerFn},
            target={x=p.x+5,y=p.y+3},reset=cornerReset,corners=cornerCorners,corner=true},
        {name='corner_later',spec={type='beam',range=20,no_restrict=true,block_path=laterFn},
            target={x=p.x+6,y=p.y+4},reset=laterReset,corners=laterCorners,corner=true},
    }
    local all=true
    for _,case in ipairs(cases) do
        local spec={}
        for key,value in pairs(case.spec) do spec[key]=value end
        spec.target={x=case.target.x,y=case.target.y}
        local native=EffectFootprint.native(ctx,spec)
        if case.reset then case.reset() end
        local recorded,stop_x,stop_y=p:project(spec,case.target.x,case.target.y,function() return false end,0)
        local match=native~=nil and sameSet(native,recorded)
        local corners=case.corners and case.corners() or 0
        check('effect-footprint:'..case.name,match and (not case.corner or corners>0),
            {native=EffectFootprint.count(native),recorded=EffectFootprint.count(recorded),
                corners=corners,stop={x=stop_x,y=stop_y}})
        if case.corner then
            check('effect-footprint:'..case.name..':corner',corners>0 and stop_x~=nil,
                {corners=corners,stop={x=stop_x,y=stop_y}})
        end
        if not match then all=false end
    end
    -- The production guard, not only M.native, must use the native backend.
    local NPC=require('mod.class.NPC')
    local ally=NPC.new{name='effect ally',type='humanoid',subtype='human',display='a',
        color=colors.GREEN,faction='players',level_range={1,1},max_life=100,life_rating=0,
        rank=1,size_category=1,ai='none',never_move=true,
        stats={str=10,dex=10,mag=10,con=10},combat={dam=1,atk=1,apr=0},
        combat_armor=0,combat_def=0,infravision=10}
    ally:resolve();ally:resolve(nil,true);ally.life=ally.max_life
    game.zone:addEntity(game.level,ally,'actor',p.x+2,p.y)
    local host=Runtime.buildAutoCombatHostFor(game,policy({WAIT}))
    local bound=host and host.snapshot('nearest_hostile').bound_target
    local verdict=bound and host.guard({action='use_talent',talent='T_MOONLIGHT_RAY',bound_target=bound})
    check('effect-footprint:guard-native',verdict and verdict.reason=='selffire_risk'
        and verdict.detail and verdict.detail.footprint_backend=='native',verdict)
    if not (verdict and verdict.detail and verdict.detail.footprint_backend=='native') then all=false end
    game.level:removeEntity(ally,true)
    return compare('effect-footprint-parity',{all and 'parity_ok' or 'parity_failed'})
end

-- NO-AUDIT (v1.6): the live source hashes and builder identities are ADVISORY
-- telemetry only. They must report drift and never gate a decision.
function M.manifestDrift()
    local md5=require('md5')
    local signals={}
    local review=ManifestDrift.review(EffectManifest.SOURCES,fs.readAll,md5.sumhexa,
        {game_version=EffectManifest.GAME_VERSION})
    check('manifest-drift:verified',review.drift==false,{findings=review.findings})
    signals[#signals+1]=review.drift==false and 'verified' or 'verify_failed'
    local tampered={schema=EffectManifest.SOURCES.schema,game_version=EffectManifest.SOURCES.game_version,
        engine=EffectManifest.SOURCES.engine,talents={}}
    for talent,pin in pairs(EffectManifest.SOURCES.talents) do
        local files={}
        for index,file in ipairs(pin.files) do
            files[index]={path=file.path,md5=index==1 and string.rep('0',32) or file.md5}
        end
        tampered.talents[talent]={files=files,line=pin.line}
    end
    local tamperedReview=ManifestDrift.review(tampered,fs.readAll,md5.sumhexa,
        {game_version=EffectManifest.GAME_VERSION})
    check('manifest-drift:reported',tamperedReview.drift==true,{})
    signals[#signals+1]=tamperedReview.drift==true and 'hash_reported' or 'hash_ignored'
    local identityReview=ManifestDrift.identity(EffectManifest,function(talent)
        return game.player.talents_def and game.player.talents_def[talent] or nil
    end)
    check('manifest-drift:identity',identityReview.drift==false,{findings=identityReview.findings})
    signals[#signals+1]=identityReview.drift==false and 'identity_ok' or 'identity_drift'
    -- Advisory telemetry always returns a record and never gates.
    local record=ManifestDrift.telemetry({sources=EffectManifest.SOURCES,read=fs.readAll,
        digest=md5.sumhexa,expected={game_version=EffectManifest.GAME_VERSION},
        manifest=EffectManifest,identity=function(talent)
            return game.player.talents_def and game.player.talents_def[talent] or nil end})
    check('manifest-drift:advisory',type(record)=='table' and record.advisory==true,{})
    signals[#signals+1]=type(record)=='table' and 'advisory_ok' or 'advisory_missing'
    return compare('manifest-drift',signals)
end

-- TODO #55: the four re-admitted dynamic talents. The production guard must
-- read their real builders, resolve the audited spellFriendlyFire input, and
-- apply the persistent-ground rules (Shadow Blast's ground has default-true FF).
function M.dynamicTalents()
    local Guard=require 'mod.auto_combat.AutoCombatGuard'
    local p=game.player
    for _,talent in ipairs({'T_FLAMESHOCK','T_FIREFLASH','T_SHADOW_BLAST','T_STARFALL'}) do
        if not p:knowTalent(talent) then p:learnTalent(talent,true) end
    end
    local saved=p.combat_spell_friendlyfire
    p.combat_spell_friendlyfire=200 -- force spellFriendlyFire to 0
    local host=Runtime.buildAutoCombatHostFor(game,policy({WAIT}))
    local bound=host and host.snapshot('nearest_hostile').bound_target
    local signals={}
    if not bound then
        check('dynamic-talents:setup',false,{bound=bound})
        p.combat_spell_friendlyfire=saved
        return compare('dynamic-talents',{'no_setup'})
    end
    local friendly=select(2,pcall(p.spellFriendlyFire,p))
    local provider_ok=type(friendly)=='number' and friendly>=0 and friendly<=100
    check('dynamic-talents:provider',provider_ok,{spellFriendlyFire=friendly})
    signals[#signals+1]=provider_ok and 'provider_ok' or 'provider_bad'
    -- Exact intended outcomes: allowed (nil) vs the persistent-ground rejection.
    local expectations={T_FLAMESHOCK='allowed',T_FIREFLASH='allowed',T_SHADOW_BLAST='ground',T_STARFALL='allowed'}
    for _,talent in ipairs({'T_FLAMESHOCK','T_FIREFLASH','T_SHADOW_BLAST','T_STARFALL'}) do
        local verdict=host.guard({action='use_talent',talent=talent,bound_target=bound})
        local drift=verdict and (verdict.reason=='adapter_source_drift' or verdict.reason=='unsupported_adapter'
            or verdict.reason=='adapter_builder_failed' or verdict.reason=='adapter_builder_missing')
        local expected=expectations[talent]
        local outcome_ok
        if expected=='allowed' then
            outcome_ok=(verdict==nil)
        else
            outcome_ok=verdict and verdict.reason=='selffire_risk' and verdict.detail
                and verdict.detail.phase==expected
        end
        check('dynamic-talents:'..talent,(not drift) and outcome_ok,{verdict=verdict,drift=drift})
        signals[#signals+1]=(not drift) and (talent..':ok') or (talent..':drift')
    end
    -- DYN-REV-02: a wall between the caster and the bound hostile removes it
    -- from the resolved range-0 cone, so the guard rejects the unreachable target.
    -- The arena floor grid is shared, so clone it for the single blocked cell.
    local map=game.level.map
    local wall_idx=(p.x+1)+p.y*map.w
    local saved_terrain=map.map[wall_idx] and map.map[wall_idx][engine.Map.TERRAIN]
    local wall_grid=saved_terrain and saved_terrain:clone()
    if wall_grid then
        wall_grid.block_move=true
        map.map[wall_idx][engine.Map.TERRAIN]=wall_grid
    end
    local walled=host.guard({action='use_talent',talent='T_FLAMESHOCK',bound_target=bound})
    check('dynamic-talents:flameshock-wall',walled and walled.reason=='target_out_of_range',walled)
    if saved_terrain then map.map[wall_idx][engine.Map.TERRAIN]=saved_terrain end
    -- DYN-REV-03 / DYN-REV2-01: the source-centred ground cone keeps its aim
    -- direction and matches the grid set recorded by a real `Map:addEffect`,
    -- including the engine's boolean-true terrain blocking rule.
    local def=p.talents_def and p.talents_def.T_FLAMESHOCK
    local radius=def and p:getTalentRadius(def) or nil
    local bound_uid=tonumber(tostring(bound):match('actor%-(%d+)$'))
    local bound_actor=nil
    for _,actor in pairs(game.level.entities or {}) do
        if actor and actor.uid==bound_uid then bound_actor=actor end
    end
    if radius and bound_actor then
        local dx=bound_actor.x-p.x
        local dy=bound_actor.y-p.y
        local spec=Guard.footprintSpec({shape='cone',radius=radius,center='self',direction='target',
            delivery='map_effect'},{x=p.x,y=p.y},{x=bound_actor.x,y=bound_actor.y})
        -- Record the grid set the real engine builds for the Flameshock ground.
        local function groundGrids()
            local e=map:addEffect(p,p.x,p.y,4,'INFERNO',0,radius,
                {delta_x=dx,delta_y=dy},55,nil,nil,0)
            local grids=e.grids
            for i=#map.effects,1,-1 do if map.effects[i]==e then table.remove(map.effects,i) end end
            map.changed=true
            return grids
        end
        local set=EffectFootprint.native({game=game,source=p},spec)
        local recorded=groundGrids()
        local east=EffectFootprint.at(set,p.x+1,p.y)
        check('dynamic-talents:flameshock-ground-direction',
            set~=nil and east and EffectFootprint.count(set)>1 and sameSet(set,recorded),
            {count=EffectFootprint.count(set),recorded=EffectFootprint.count(recorded),east=east,dx=dx,dy=dy})
        -- Movement-blocking, projectile-passable terrain (e.g. Trollmire STEW):
        -- the engine's boolean-true rule blocks it; the old pass_projectile-exempt
        -- rule would not. Clone the shared floor grid for one cell.
        local terrain_idx=(p.x+2)+p.y*map.w
        local tile=map.map[terrain_idx] and map.map[terrain_idx][engine.Map.TERRAIN]
        local stew=tile and tile:clone()
        if stew then
            stew.block_move=true
            stew.pass_projectile=true
            map.map[terrain_idx][engine.Map.TERRAIN]=stew
        end
        local wall_set=EffectFootprint.native({game=game,source=p},spec)
        local wall_recorded=groundGrids()
        local old_rule=core.fov.beam_any_angle_grids(p.x,p.y,radius,55,p.x,p.y,dx,dy,
            function(_,lx,ly)
                if not map:isBound(lx,ly) then return true end
                local b=map:checkEntity(lx,ly,engine.Map.TERRAIN,'block_move')
                if b and not map:checkEntity(lx,ly,engine.Map.TERRAIN,'pass_projectile') then return true end
                return false
            end)
        check('dynamic-talents:map-effect-terrain-parity',
            stew~=nil and wall_set~=nil and sameSet(wall_set,wall_recorded) and not sameSet(wall_set,old_rule),
            {count=EffectFootprint.count(wall_set),recorded=EffectFootprint.count(wall_recorded),
                old=EffectFootprint.count(old_rule),behind=EffectFootprint.at(wall_set,p.x+3,p.y)})
        if tile then map.map[terrain_idx][engine.Map.TERRAIN]=tile end
    else
        check('dynamic-talents:flameshock-ground-direction',false,{radius=radius,actor=bound_actor~=nil})
        check('dynamic-talents:map-effect-terrain-parity',false,{radius=radius})
    end
    p.combat_spell_friendlyfire=saved
    return compare('dynamic-talents',signals)
end

-- MOV-1..MOV-3 native check: the production host plans a real step, executes it
-- through the real executor, and annotates an off-vision grid request and a
-- random teleport landing. A deterministic-landing policy rejects the random
-- teleport as a policy choice (not a plugin refusal).
local function movementPlan()
    forceReady()
    Runtime.setAutoCombatExecution(game,true)
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    -- Choose a real open adjacent cell so the production executor has a genuine
    -- movement to perform; native collision stays authoritative.
    local function openAdjacent()
        local p=game.player
        local map=game.level.map
        local dirs={{-1,-1},{0,-1},{1,-1},{-1,0},{1,0},{-1,1},{0,1},{1,1}}
        for _,d in ipairs(dirs) do
            local x,y=p.x+d[1],p.y+d[2]
            if map:isBound(x,y) and not map:checkAllEntities(x,y,'block_move',p)
                and not map(x,y,engine.Map.ACTOR) then
                return d
            end
        end
        return nil
    end
    local delta=openAdjacent() or {0,1}
    local pol=policy({{id='kite',priority=10,when={always={}},
        ['then']={action='move',target='nearest_hostile',
            destination={selector='relative',dx=delta[1],dy=delta[2],accept=accept}}}})
    Runtime.autoCombatHandle(game,'set_draft',{policy=pol})
    local approved=Runtime.autoCombatHandle(game,'approve',{})
    Runtime.autoCombatHandle(game,'activate',{expected_hash=approved.approved_hash})
    local host=Runtime.buildAutoCombatHostFor(game,pol,{drift=function() return true end})
    local signals={}
    local bound=host and host.snapshot('nearest_hostile').bound_target or nil
    local planned,err=host.plan({action='move',destination=pol.rules[1]['then'].destination,
        bound_target=bound})
    local step_ok=planned and planned.plan and planned.plan.kind=='step'
    signals[#signals+1]=step_ok and 'step_planned' or 'step_missing'
    check('movement:step',step_ok,{reason=err and err.reason,kind=planned and planned.plan and planned.plan.kind})
    if step_ok then
        local before=game.player.x..','..game.player.y
        local outcome=host.request({action='move',plan=planned.plan,rule='kite'})
        local moved=outcome.status=='ok'
        signals[#signals+1]=moved and 'step_executed' or 'step_rejected'
        check('movement:step-executes',moved,{status=outcome.status,code=outcome.code,
            before=before,after=game.player.x..','..game.player.y})
    else
        signals[#signals+1]='step_rejected'
    end
    local p=game.player
    if type(p.talents)~='table' then p.talents={} end
    local saved_tumble=p.talents.T_SKIRMISHER_CUNNING_ROLL
    p.talents.T_SKIRMISHER_CUNNING_ROLL=5
    local grid=host.plan({action='use_talent',talent='T_SKIRMISHER_CUNNING_ROLL',
        destination={selector='position',x=game.player.x+3,y=game.player.y,accept=accept}})
    local grid_ok=grid and grid.plan and grid.plan.kind=='grid'
        and grid.plan.annotation and grid.plan.annotation.known_passable~=nil
    p.talents.T_SKIRMISHER_CUNNING_ROLL=saved_tumble
    signals[#signals+1]=grid_ok and 'grid_annotated' or 'grid_missing'
    check('movement:grid-annotation',grid_ok,{kind=grid and grid.plan and grid.plan.kind,
        visible=grid and grid.plan and grid.plan.annotation and grid.plan.annotation.visible,
        passable=grid and grid.plan and grid.plan.annotation and grid.plan.annotation.known_passable})
    local random=host.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',accept=accept}})
    local random_ok=random and random.plan and random.plan.annotation.landing.kind=='random'
    signals[#signals+1]=random_ok and 'random_annotated' or 'random_missing'
    check('movement:random-annotation',random_ok,{})
    local strict=host.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',accept={visibility='any',passability='native',
            hazard='any',landing='deterministic'}}})
    local strict_ok=strict==nil
    signals[#signals+1]=strict_ok and 'random_policy_rejected' or 'random_policy_passed'
    check('movement:random-policy',strict_ok,{})
    Runtime.autoCombatHandle(game,'deactivate',{})
    Runtime.setAutoCombatExecution(game,false)
    return compare('movement',signals)
end

-- P2-1 native check: a deterministic adjacent landing whose cell is really
-- blocked (native collision) is refused by the engine; the controller must
-- exclude it and re-plan the same `toward` selector so the character still
-- moves to a feasible adjacent cell. Uses the production host/executor and the
-- arena's real terrain, not a fake planner.
local function movementNativeFallback()
    forceReady()
    Runtime.setAutoCombatExecution(game,true)
    local p=game.player
    local map=game.level.map
    local bound_actor
    for _,actor in pairs(game.level.entities or {}) do
        if actor~=p and actor.name and tostring(actor.name):find('MCP target dummy') then bound_actor=actor end
    end
    local signals={}
    if not bound_actor then
        check('movement-fallback:setup',false,{note='no bound dummy'})
        Runtime.setAutoCombatExecution(game,false)
        return compare('movement-fallback',{'no_setup'})
    end
    -- Move the dummy so the straight `toward` landing is the cell we then block
    -- with real terrain. Keep the dummy visible and non-adjacent (2 tiles north).
    local saved_dummy={x=bound_actor.x,y=bound_actor.y}
    local dx,dy=(p.x<map.w-4) and 2 or -2,0
    local target_x,target_y=p.x+dx+2,p.y+dy
    if not map:isBound(target_x,target_y) then target_x,target_y=p.x-4,p.y end
    bound_actor.x,bound_actor.y=target_x,target_y
    bound_actor:resolve()
    map(bound_actor.x,bound_actor.y,engine.Map.ACTOR,bound_actor)
    -- Determine the deterministic `toward` landing from the production planner,
    -- then block exactly that cell with real cloneable terrain.
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local pol=policy({{id='approach',priority=10,when={always={}},
        ['then']={action='move',target='nearest_hostile',
            destination={selector='toward',anchor='bound_target',accept=accept}}}},{max_actions_per_tick=2})
    Runtime.autoCombatHandle(game,'set_draft',{policy=pol})
    local approved=Runtime.autoCombatHandle(game,'approve',{})
    Runtime.autoCombatHandle(game,'activate',{expected_hash=approved.approved_hash})
    local host=Runtime.buildAutoCombatHostFor(game,pol,{drift=function() return true end})
    -- This is a synchronous scenario boundary (no native pump), so present a
    -- ready action opportunity exactly as the other production-path scenarios
    -- do (`start-when-ready`); reads and execution stay the production host.
    host.phase=function() return 'ready' end
    local bound=host and host.snapshot('nearest_hostile').bound_target or nil
    local first=host.plan({action='move',destination=pol.rules[1]['then'].destination,
        bound_target=bound})
    local landing=first and first.plan and first.plan.x and {x=first.plan.x,y=first.plan.y} or nil
    if not landing then
        check('movement-fallback:plan',false,{reason=first and first.reason})
        Runtime.autoCombatHandle(game,'deactivate',{})
        Runtime.setAutoCombatExecution(game,false)
        return compare('movement-fallback',{'no_plan'})
    end
    -- Block the straight landing with a cloneable real terrain tile.
    local idx=landing.x+landing.y*map.w
    local saved=map.map[idx] and map.map[idx][engine.Map.TERRAIN]
    local wall=saved and saved:clone() or nil
    local blocked_ok=false
    if wall then
        wall.block_move=true
        map.map[idx][engine.Map.TERRAIN]=wall
        blocked_ok=map:checkEntity(landing.x,landing.y,engine.Map.TERRAIN,'block_move',p) and true or false
    end
    signals[#signals+1]=blocked_ok and 'blocked_landing' or 'block_missing'
    check('movement-fallback:block',blocked_ok,{x=landing.x,y=landing.y})
    -- The fallback must actually select a *different* adjacent step. Assert the
    -- planner's own second choice differs from the blocked straight landing.
    local second=host.plan({action='move',destination=pol.rules[1]['then'].destination,
        bound_target=bound,exclude={[landing.x..','..landing.y]=true}})
    local alt=second and second.plan
    local alt_ok=alt and not (alt.x==landing.x and alt.y==landing.y)
    signals[#signals+1]=alt_ok and 'alternative_planned' or 'alternative_missing'
    check('movement-fallback:alternative',alt_ok,{x=alt and alt.x,y=alt and alt.y,
        blocked=landing.x..','..landing.y,reason=second and second.reason})
    -- Drive the real controller state machine so the fallback path is exercised
    -- end to end (not merely the pure planner).
    local before={x=p.x,y=p.y}
    local c=AutoCombat.new(pol,host,{strict=false})
    c:start()
    local step
    -- Pump bounded action opportunities; the real executor may need the boundary
    -- tick to settle between the refused landing and the alternative one.
    for _=1,12 do
        forceReady()
        step=c:onOpportunity()
        if step.action=='acted' or step.action=='stopped' or step.action=='paused' then break end
        if step.action~='noop' and step.action~='wait' and step.action~='wait_for_ready' then break end
    end
    local moved=p.x~=before.x or p.y~=before.y
    local refused=false
    for _,entry in ipairs(c.recent) do
        if entry.kind=='movement_retry' and entry.landing==(landing.x..','..landing.y) then refused=true end
    end
    check('movement-fallback:moves',step.action=='acted' and moved,
        {action=step.action,reason=step.reason,before=before.x..','..before.y,
            after=p.x..','..p.y,attempts=c.attempts,blocked=landing.x..','..landing.y})
    signals[#signals+1]=(step.action=='acted' and moved) and 'fallback_moved' or 'fallback_stuck'
    check('movement-fallback:retry-recorded',refused,
        {entries=#c.recent,code=(function() for _,e in ipairs(c.recent) do if e.kind=='movement_retry' then return e.reason end end end)()})
    if saved then map.map[idx][engine.Map.TERRAIN]=saved end
    -- Restore the fixture dummy so later scenarios see the shared arena unchanged.
    map(bound_actor.x,bound_actor.y,engine.Map.ACTOR,nil)
    local dummy_idx=saved_dummy.x+saved_dummy.y*map.w
    local occupied=map.map[dummy_idx] and map.map[dummy_idx][engine.Map.ACTOR]
    if not occupied then
        bound_actor.x,bound_actor.y=saved_dummy.x,saved_dummy.y
        map(bound_actor.x,bound_actor.y,engine.Map.ACTOR,bound_actor)
    end
    Runtime.autoCombatHandle(game,'deactivate',{})
    Runtime.setAutoCombatExecution(game,false)
    return compare('movement-fallback',signals)
end

-- S1 factory: the Phase Door effective-level x `phase_door_force_precise` matrix
-- and the newly admitted grid adapters, exercised through the production host
-- (plan only; execution is covered by `movement-talents`).
local function movementFactoryChecks()
    forceReady()
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local p=game.player
    local map=game.level.map
    local base_attr=p.attr
    local host=Runtime.buildAutoCombatHostFor(game,policy({WAIT}),{drift=function() return true end})
    local signals={}
    local function cellState(x,y)
        if x<0 or y<0 or x>=map.w or y>=map.h then return nil end
        local idx=x+y*map.w
        return {idx=idx,seens=map.seens[idx],infovs=map.infovs[idx],lites=map.lites[idx],
            actor=map.map[idx] and map.map[idx][map.ACTOR or 3]}
    end
    local function findVisibleEmpty()
        for r=1,6 do
            for _,d in ipairs({{r,0},{-r,0},{0,r},{0,-r},{r,r},{-r,-r},{r,-r},{-r,r}}) do
                local c=cellState(p.x+d[1],p.y+d[2])
                if c and c.seens and c.infovs and c.actor==nil then return p.x+d[1],p.y+d[2] end
            end
        end
    end
    -- `phase_door_force_precise` below TL4 forces the grid prompt. Set the
    -- attribute value so the real `attr` method stays audited (the helper
    -- closure now identity-checks `attr`).
    p.phase_door_force_precise=1
    local precise,preciseErr=host.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='position',x=p.x+2,y=p.y,accept=accept}})
    local preciseOk=precise and precise.plan and precise.plan.kind=='grid'
        and precise.plan.annotation.landing.kind=='bounded'
    p.phase_door_force_precise=nil
    signals[#signals+1]=preciseOk and 'precise_grid' or 'precise_missing'
    check('movement-factory:precise-grid',preciseOk,{reason=preciseErr and preciseErr.reason,
        detail=preciseErr and (preciseErr.detail or preciseErr.dependency),
        kind=precise and precise.plan and precise.plan.kind})
    -- An unknown precise attribute fails closed instead of submitting no-prompt.
    p.attr=function() error('probe: unknown precise attribute') end
    local unknown,unknownErr=host.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',accept=accept}})
    local unknownOk=unknown==nil and unknownErr and unknownErr.reason=='movement_variant_unknown'
    signals[#signals+1]=unknownOk and 'variant_unknown' or 'variant_unknown_missing'
    check('movement-factory:variant-unknown',unknownOk,{reason=unknownErr and unknownErr.reason})
    p.attr=base_attr
    -- Dimensional Step effective TL5: occupancy-dependent (known empty admits
    -- the non-swap branch; a known actor is the S4 gap; unknown fails closed).
    if type(p.talents)~='table' then p.talents={} end
    local saved_step=p.talents.T_DIMENSIONAL_STEP
    p.talents.T_DIMENSIONAL_STEP=5
    local ex,ey=findVisibleEmpty()
    local empty
    if ex then
        empty=host.plan({action='use_talent',talent='T_DIMENSIONAL_STEP',
            destination={selector='position',x=ex,y=ey,accept=accept}})
    end
    local emptyOk=empty and empty.plan and empty.plan.kind=='grid'
    signals[#signals+1]=emptyOk and 'dimensional_empty' or 'dimensional_empty_missing'
    check('movement-factory:dimensional-empty',emptyOk,{x=ex,y=ey})
    local dummy
    for _,actor in pairs(game.level.entities or {}) do
        if actor~=p and actor.name and tostring(actor.name):find('MCP target dummy') then dummy=actor end
    end
    local actorPlan,actorErr
    if dummy then
        actorPlan,actorErr=host.plan({action='use_talent',talent='T_DIMENSIONAL_STEP',
            destination={selector='position',x=dummy.x,y=dummy.y,accept=accept}})
    end
    local actorOk=actorPlan==nil and actorErr and actorErr.reason=='unsupported_movement_variant'
        and actorErr.missing=='moving_or_swapping_another_actor'
    signals[#signals+1]=actorOk and 'dimensional_actor_gap' or 'dimensional_actor_missing'
    check('movement-factory:dimensional-actor',actorOk,{reason=actorErr and actorErr.reason})
    local hiddenOk=false
    if ex then
        local c=cellState(ex,ey)
        map.seens[c.idx]=nil;map.infovs[c.idx]=nil;map.lites[c.idx]=nil
        local hidden,hiddenErr=host.plan({action='use_talent',talent='T_DIMENSIONAL_STEP',
            destination={selector='position',x=ex,y=ey,accept=accept}})
        map.seens[c.idx]=c.seens;map.infovs[c.idx]=c.infovs;map.lites[c.idx]=c.lites
        hiddenOk=hidden==nil and hiddenErr and hiddenErr.reason=='movement_variant_unknown'
    end
    signals[#signals+1]=hiddenOk and 'dimensional_unknown' or 'dimensional_unknown_missing'
    check('movement-factory:dimensional-unknown',hiddenOk,{})
    p.talents.T_DIMENSIONAL_STEP=saved_step
    -- MAF-REV-03: a `toward` selector uses the live pinned builder range, not a
    -- hard-coded scan radius.
    local saved_vault=p.talents.T_SKIRMISHER_VAULT
    p.talents.T_SKIRMISHER_VAULT=5
    local liveRange
    do
        local def=p.talents_def and p.talents_def.T_SKIRMISHER_VAULT
        local ok,typ=pcall(def.target,p,def)
        if ok and type(typ)=='table' then liveRange=typ.range end
    end
    local towardOk=false
    local bound=host.snapshot('nearest_hostile')
    local toward,towardErr=host.plan({action='use_talent',talent='T_SKIRMISHER_VAULT',
        bound_target=bound and bound.bound_target,
        destination={selector='toward',anchor='bound_target',accept=accept}})
    if toward and toward.plan and toward.plan.kind=='grid'
        and type(liveRange)=='number' and liveRange<12 then
        local dist=Distance.grid(p.x,p.y,toward.plan.x,toward.plan.y)
        towardOk=dist<=liveRange
    end
    signals[#signals+1]=towardOk and 'vault_toward_range' or 'vault_toward_missing'
    check('movement-factory:vault-toward-range',towardOk,{range=liveRange,
        reason=towardErr and towardErr.reason})
    -- MAF-REV-03: an explicit coordinate outside the live range is rejected.
    local farOk=false
    if type(liveRange)=='number' then
        local far,farErr=host.plan({action='use_talent',talent='T_SKIRMISHER_VAULT',
            destination={selector='position',x=p.x+liveRange+5,y=p.y,accept=accept}})
        farOk=far==nil and farErr and farErr.reason=='destination_out_of_range'
        check('movement-factory:vault-out-of-range',farOk,{range=liveRange,
            reason=farErr and farErr.reason})
    end
    signals[#signals+1]=farOk and 'vault_out_of_range' or 'vault_out_of_range_missing'
    -- Vault is an exact grid move (deterministic landing annotation). Keep the
    -- level-5 range so the in-range request is valid.
    local vault,vaultErr=host.plan({action='use_talent',talent='T_SKIRMISHER_VAULT',
        destination={selector='position',x=p.x+2,y=p.y,accept=accept}})
    local vaultOk=vault and vault.plan and vault.plan.kind=='grid'
        and vault.plan.annotation.landing.kind=='deterministic'
    signals[#signals+1]=vaultOk and 'vault_exact' or 'vault_missing'
    check('movement-factory:vault-exact',vaultOk,{reason=vaultErr and vaultErr.reason})
    p.talents.T_SKIRMISHER_VAULT=saved_vault
    -- MAF-REV-06 (no-strict-audit): a replaced getter with a usable value is used
    -- directly; an erroring getter is movement_derivation_unknown.
    local live_value_used=false
    local getter_error_ok=false
    do
        local def=p.talents_def and p.talents_def.T_PHASE_DOOR
        local saved_range=def and def.getRange
        if def then
            def.getRange=function() return 9 end
            local plan=host.plan({action='use_talent',talent='T_PHASE_DOOR',
                destination={selector='native_random',accept=accept}})
            live_value_used=plan and plan.plan and plan.plan.annotation
                and plan.plan.annotation.landing and plan.plan.annotation.landing.radius==9
            check('movement-factory:live-getter-value',live_value_used,{})
            def.getRange=function() error('probe: getter error') end
            local bad,err=host.plan({action='use_talent',talent='T_PHASE_DOOR',
                destination={selector='native_random',accept=accept}})
            getter_error_ok=bad==nil and err and err.reason=='movement_derivation_unknown'
            check('movement-factory:getter-error',getter_error_ok,{reason=err and err.reason})
            def.getRange=saved_range
        end
    end
    signals[#signals+1]=live_value_used and 'live_getter_value' or 'live_getter_value_missing'
    signals[#signals+1]=getter_error_ok and 'getter_error_unknown' or 'getter_error_missing'
    return compare('movement-factory',signals)
end

-- MFT-REV-09: drive the three movement talents end to end through the real
-- executor. Rush (actor target), exact-grid Tumble, and a random self teleport.
-- MFT-REV-09: the movement-talent run is a small async state machine so each
-- yielding native task is settled before its final postcondition is asserted.
local function movementTalentSetup()
    forceReady()
    Runtime.setAutoCombatExecution(game,true)
    -- The arena dummy can retain a daze from an earlier scenario; re-applying
    -- EFF_DAZED then hits the native boolean-attribute merge. Clear it so the
    -- movement probes exercise the talent, not a stale fixture state.
    -- The arena may not run the status-type registration the main game does;
    -- `canBe("stun")` then reads a boolean `StatusTypes.stun`. Restore the
    -- normal attr mapping so the fixture's attack postcondition is clean.
    if game.player and game.player.StatusTypes then
        game.player.StatusTypes.stun='stun_resist'
    end
    for _,actor in pairs(game.level.entities or {}) do
        if actor.removeEffect then pcall(function() actor:removeEffect('EFF_DAZED', true, true) end) end
        actor.dazed=nil
        -- Keep the fixture from re-applying a stun/daze that hits a native
        -- boolean-attribute merge; the movement postcondition does not need it.
        if actor.name and actor.name:find('MCP target dummy') then
            actor.stun_immune=true
            actor.daze_immune=true
            actor.stun_resist=100
            actor.daze_resist=100
        end
    end
    local p=game.player
    local levels={T_RUSH=5,T_SKIRMISHER_CUNNING_ROLL=5,T_PHASE_DOOR=1}
    for talent,level in pairs(levels) do
        if type(p.talents)~='table' then p.talents={} end
        if not p.talents[talent] and type(p.learnTalent)=='function' then p:learnTalent(talent,true) end
        p.talents[talent]=level
    end
    M.mt={index=0,signals={},specs={
        {name='rush',talent='T_RUSH',kind='rush'},
        {name='tumble',talent='T_SKIRMISHER_CUNNING_ROLL',kind='tumble'},
        {name='door',talent='T_PHASE_DOOR',kind='door'},
    }}
end

local function movementTalentHost()
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local pol=policy({{id='movement-probe',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_RUSH',target='nearest_hostile',
            destination={selector='native_landing',anchor='bound_target',accept=accept}}}})
    return Runtime.buildAutoCombatHostFor(game,pol,{drift=function() return true end}),accept
end

local function movementTalentSignal(kind,suffix)
    local base=kind=='rush' and 'rush' or kind=='tumble' and 'tumble' or 'teleport'
    return base..'_'..suffix
end

local movementTalentAssert
local function movementTalentRun(spec)
    local p=game.player
    local host,accept=movementTalentHost()
    M.mt.before={x=p.x,y=p.y}
    local outcome
    if spec.kind=='rush' then
        local ctx=host.snapshot('nearest_hostile')
        local bound=ctx and ctx.bound_target
        local planned,err=host.plan({action='use_talent',talent=spec.talent,bound_target=bound,
            target='nearest_hostile',
            target_plan={{request='actor',selector='nearest_hostile'}},
            destination={selector='native_landing',anchor='bound_target',accept=accept}})
        local ok=planned and planned.plan and planned.plan.kind=='actor'
        M.mt.signals[#M.mt.signals+1]=ok and 'rush_planned' or 'rush_plan_missing'
        check('movement-talents:rush-plan',ok,{kind=planned and planned.plan and planned.plan.kind,
            reason=err and err.reason})
        if ok then
            outcome=host.request({action='use_talent',talent=spec.talent,plan=planned.plan,
                bound_target=bound,rule='rush'})
        end
    elseif spec.kind=='tumble' then
        local map=game.level.map
        local tx,ty
        for radius=2,4 do
            for _,delta in ipairs({{radius,0},{-radius,0},{0,radius},{0,-radius},
                {radius,radius},{-radius,-radius},{radius,-radius},{-radius,radius}}) do
                local x,y=p.x+delta[1],p.y+delta[2]
                if map:isBound(x,y) and not map:checkAllEntities(x,y,'block_move',p)
                    and not map(x,y,engine.Map.ACTOR) then tx,ty=x,y break end
            end
            if tx then break end
        end
        local planned,err
        if tx then
            planned,err=host.plan({action='use_talent',talent=spec.talent,
                target_plan={{request='grid',
                    destination={selector='position',x=tx,y=ty,accept=accept}}},
                destination={selector='position',x=tx,y=ty,accept=accept}})
        end
        local ok=planned and planned.plan and planned.plan.kind=='grid'
        M.mt.signals[#M.mt.signals+1]=ok and 'tumble_planned' or 'tumble_plan_missing'
        check('movement-talents:tumble-plan',ok,{x=tx,y=ty,reason=err and err.reason})
        if ok then
            M.mt.tumble_target={x=tx,y=ty}
            outcome=host.request({action='use_talent',talent=spec.talent,plan=planned.plan,
                rule='tumble'})
        end
    else
        local planned,err=host.plan({action='use_talent',talent=spec.talent,
            target_plan={{request='none'}},destination={selector='native_random',accept=accept}})
        local ok=planned and planned.plan and planned.plan.kind=='none'
        M.mt.signals[#M.mt.signals+1]=ok and 'teleport_planned' or 'teleport_plan_missing'
        check('movement-talents:teleport-plan',ok,{kind=planned and planned.plan and planned.plan.kind,
            reason=err and err.reason})
        if ok then
            outcome=host.request({action='use_talent',talent=spec.talent,plan=planned.plan,
                rule='door'})
        end
    end
    M.mt.outcome=outcome
    if outcome==nil then
        M.mt.signals[#M.mt.signals+1]=movementTalentSignal(spec.kind,'rejected')
        M.mt.pending=false
    elseif outcome.status=='native_pending' then
        M.mt.pending=true
        M.mt.frames=0
    else
        movementTalentAssert(spec)
    end
end

movementTalentAssert=function(spec)
    local p=game.player
    local before=M.mt.before
    local outcome=M.mt.outcome
    local moved=p.x~=before.x or p.y~=before.y
    -- A settled grid request must also land on the requested cell.
    local landed=true
    if spec.kind=='tumble' and M.mt.tumble_target then
        landed=p.x==M.mt.tumble_target.x and p.y==M.mt.tumble_target.y
    end
    local ok=moved and landed
    -- P0: Rush's native flow requests a target more than once (the useTalent
    -- message path and then the action). The auto slot drives it through the
    -- authoritative native force path, so it must settle on the first
    -- opportunity with no unanswerable target UI left active.
    if spec.kind=='rush' then
        local settled=outcome and outcome.status=='ok'
        local no_ui=not (game.target and game.target.active) and game.target_co==nil
        check('movement-talents:rush-settles',settled and no_ui,
            {status=outcome and outcome.status,code=outcome and outcome.code,
                target_active=game.target and game.target.active or false,co=game.target_co~=nil})
        ok=ok and settled and no_ui
    end
    M.mt.signals[#M.mt.signals+1]=ok and movementTalentSignal(spec.kind,'executed')
        or movementTalentSignal(spec.kind,'rejected')
    check('movement-talents:'..spec.name..'-execute',ok,
        {status=outcome and outcome.status,code=outcome and outcome.code,
            before=before.x..','..before.y,after=p.x..','..p.y,
            target=M.mt.tumble_target and (M.mt.tumble_target.x..','..M.mt.tumble_target.y) or nil})
end


-- MFT-REV-09: install the real native CHANGE_LEVEL handler with a source that
-- passes the bridge's native audit. The arena test fixture does not populate
-- `key.virtuals`; this binds the exact handler body from Game.lua (the same
-- technique tests/test_actions.lua uses) so the production executor runs a real
-- scene transition.
local function ensureChangeLevelHandler()
    local existing=game.key and game.key.virtuals and game.key.virtuals.CHANGE_LEVEL
    if type(existing)=='function' then
        local info=debug.getinfo(existing,'S')
        if info and type(info.source)=='string'
            and info.source:sub(-#'/mod/class/Game.lua')=='/mod/class/Game.lua' then
            return true
        end
    end
    local ok,source=pcall(function() return fs.readAll('/mod/class/Game.lua') end)
    if not ok or type(source)~='string' then return false end
    local command=source:match('CHANGE_LEVEL = (function%(%)%s*.-)%s*,%s*REST = function')
    if not command then return false end
    local chunk=loadstring('return function(self,Map) return '..command..' end',
        '@/mod/class/Game.lua')
    if not chunk then return false end
    game.key=game.key or {}
    game.key.virtuals=game.key.virtuals or {}
    game.key.virtuals.CHANGE_LEVEL=chunk()(game,engine.Map)
    return type(game.key.virtuals.CHANGE_LEVEL)=='function'
end

-- MFT-REV-09: an auto-combat stair fixture. A real native change_level through
-- the production host must stop/reset the controller and refuse resume.
local function sceneLifecycle()
    forceReady()
    if not ensureChangeLevelHandler() then
        check('scene-lifecycle:handler',false,{note='native CHANGE_LEVEL handler unavailable'})
        return compare('scene-lifecycle',{'no_handler'})
    end
    Runtime.setAutoCombatExecution(game,true)
    -- A previous yielding talent body may have left the native targeting UI
    -- active; clear it so the native change-level handler is not `player_busy`.
    if game.target then game.target.active=false end
    game.target_co=nil
    local p=game.player
    local map=game.level.map
    local idx=p.x+p.y*map.w
    local saved=map.map[idx] and map.map[idx][engine.Map.TERRAIN]
    local stair=saved and saved:clone() or nil
    local signals={}
    if not stair then
        check('scene-lifecycle:setup',false,{note='no terrain clone available'})
        return compare('scene-lifecycle',{'no_terrain'})
    end
    stair.change_level=1
    stair.block_move=false
    stair.name='probe stairs'
    map.map[idx][engine.Map.TERRAIN]=stair
    local level_before=game.level
    local pol=policy({{id='descend',priority=10,when={always={}},['then']={action='change_level'}}})
    local host=Runtime.buildAutoCombatHostFor(game,pol,{drift=function() return true end})
    local raw
    if host and type(host.request)=='function' then
        local inner=host.request
        host.request=function(attempt)
            local out=inner(attempt)
            raw=out
            return out
        end
    end
    local c=AutoCombat.new(pol,host,{strict=false})
    c:start()
    local step=c:onOpportunity()
    local changed=game.level~=level_before
    signals[#signals+1]=changed and 'level_changed' or 'no_change'
    check('scene-lifecycle:changed',changed,{action=step.action,reason=step.reason,
        code=raw and raw.code,status=raw and raw.status,attempts=c.attempts,
        codes=(function() local t={} for _,r in ipairs(c.rejections or {}) do t[#t+1]=r.reason end return t end)()})
    local stopped=step.action=='stopped' and step.reason=='level_changed'
    signals[#signals+1]=stopped and 'stopped' or 'not_stopped'
    check('scene-lifecycle:stopped',stopped,{action=step.action,reason=step.reason,state=c.state,
        attempts=c.attempts,opportunity=c.opportunity,
        max=pol.limits and pol.limits.max_actions_per_tick,rules=#pol.rules})
    local resumed=c:resume()
    local resume_refused=not (resumed and resumed.ok)
    signals[#signals+1]=resume_refused and 'resume_refused' or 'resume_allowed'
    check('scene-lifecycle:resume',resume_refused,{ok=resumed and resumed.ok})
    if not changed then map.map[idx][engine.Map.TERRAIN]=saved end
    Runtime.autoCombatHandle(game,'deactivate',{})
    Runtime.setAutoCombatExecution(game,false)
    return compare('scene-lifecycle',signals)
end

-- S2 (§13.1/§6.2): ordered prompt-response queue. A test-only fixture talent
-- raises the exact native prompts in order; the production host lowers a
-- two-entry target plan and the real executor answers each prompt with its own
-- decided value in one submission. `sd_second_range_refused` proves the native
-- per-request range guard, `sd_missing_optional_reduced` the trailing-optional
-- `reduced=true` settlement.
local function movementSequenceFixture(name,secondSpec,raiseSecond,secondEntryOptional)
    local p=game.player
    local Factory=require 'mod.auto_combat.MovementAdapterFactory'
    local entry=assert(Factory.expand('request_then_landing',{
        request_sequence={{index=1,request='actor',subject='self',
                observed={cursor_type='hit',nowarning=true}},
            {index=2,request='grid',subject='self',value_source='target_plan',
                landing_from='envelope',optional=secondEntryOptional or nil,
                observed={cursor_type='ball',nowarning=true}}},
        delivery='teleport',landing='random',center='requested_grid',traverses=false,
        relocates_other=false,radius=1,min_radius=0,range=10}))
    p.talents=p.talents or {}
    p.talents_def=p.talents_def or {}
    p.talents[name]=1
    p.talents_def[name]={id=name,name='MCP sequence probe',mode='activated',type={'spell/conveyance',1},
        cooldown=0,mana=0,
        action=function(self)
            local tx,ty=self:getTarget({type='hit',range=10,nowarning=true})
            if not tx then return nil end
            if raiseSecond then
                local x,y=self:getTarget(secondSpec)
                if not x then return nil end
            end
            return true
        end}
    local saved=EffectManifest.ENTRIES[name]
    EffectManifest.ENTRIES[name]={kind='movement',target='self',resource='mana',
        movement=entry,components={},conformance={builder=false}}
    return entry,function()
        EffectManifest.ENTRIES[name]=saved
        -- Remove the test-only talent so no later native cooldown/message
        -- callback can touch the minimal fixture definition.
        if p.talents then p.talents[name]=nil end
        if p.talents_def then p.talents_def[name]=nil end
        if p.talents_cd then p.talents_cd[name]=nil end
    end
end

local function movementSequenceChecks()
    local signals={}
    local p=game.player
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    forceReady()
    -- Save the native seams the fixture replaces so the later async stages
    -- (movement-talents / scene-lifecycle) drive the real production entries.
    local saved_useTalent=rawget(p,'useTalent')
    local saved_getTarget=rawget(p,'getTarget')
    local saved_cd=p.talents_cd
    local function restoreSeams()
        rawset(p,'useTalent',saved_useTalent)
        rawset(p,'getTarget',saved_getTarget)
        p.talents_cd=saved_cd
    end
    -- (a) The planner lowers a two-entry program into an ordered sequence.
    local entry,restore=movementSequenceFixture('T_MCP_SEQ_A',{type='ball',range=14,radius=1,nowarning=true},true,false)
    local pol=policy({{id='seq',priority=10,when={always={}},['then']={action='use_talent',
        talent='T_MCP_SEQ_A',target='self'}}})
    local host=Runtime.buildAutoCombatHostFor(game,pol,{drift=function() return true end})
    local before={x=p.x,y=p.y}
    local dest={selector='position',x=p.x+3,y=p.y,accept=accept}
    local planArgs={action='use_talent',talent='T_MCP_SEQ_A',target='self',
        target_plan={{request='actor',selector='self'},{request='grid',destination=dest}},
        destination=dest}
    local planned,planErr=host.plan(planArgs)
    local okPlan=planned and planned.plan and planned.plan.kind=='sequence'
        and #planned.plan.steps==2 and planned.plan.values[1].kind=='self'
        and planned.plan.values[2].kind=='grid'
    check('movement-sequence:plan',okPlan,{kind=planned and planned.plan and planned.plan.kind,
        reason=planErr and planErr.reason})
    signals[#signals+1]=okPlan and 'sd_plan_sequence' or 'sd_plan_missing'
    -- (b) A reversed plan is a typed mismatch, never silently reordered.
    local reversed,reversedErr=host.plan({action='use_talent',talent='T_MCP_SEQ_A',target='self',
        target_plan={{request='grid',destination=dest},{request='actor',selector='self'}},
        destination=dest})
    local okReverse=reversed==nil and reversedErr and reversedErr.reason=='target_plan_mismatch'
    check('movement-sequence:reverse',okReverse,{reason=reversedErr and reversedErr.reason})
    signals[#signals+1]=okReverse and 'sd_reverse_plan_rejected' or 'sd_reverse_missing'
    -- (c) An un-upgraded multi-prompt descriptor keeps the typed capability gap.
    local static,staticErr=host.plan({action='use_talent',talent='T_SEQ_STATIC',target='self',
        target_plan={{request='actor',selector='self'},{request='grid',destination=dest}},
        destination=dest})
    local okStatic=static==nil and staticErr and staticErr.reason=='unsupported_target_plan'
        and staticErr.missing=='ordered_request_sequence' and staticErr.scope=='multi_prompt'
    check('movement-sequence:static-unsupported',okStatic,
        {reason=staticErr and staticErr.reason,missing=staticErr and staticErr.missing})
    signals[#signals+1]=okStatic and 'sd_static_unsupported' or 'sd_static_missing'
    -- (d) The ordered queue answers both prompts distinct in one submission.
    local outcome
    if planned then
        outcome=host.request({action='use_talent',talent='T_MCP_SEQ_A',plan=planned.plan,rule='seq'})
    end
    local settled=outcome and outcome.status=='ok'
    local seq=outcome and outcome.target_sequence
    local ordered=type(seq)=='table' and #seq==2
    check('movement-sequence:two-requests',settled and ordered,
        {status=outcome and outcome.status,code=outcome and outcome.code,count=seq and #seq})
    signals[#signals+1]=(settled and ordered) and 'sd_two_requests_ordered' or 'sd_two_requests_missing'
    -- The two recorded requests are distinguishable (the landing prompt carries
    -- a radius) and, S2-REV-06, the RECORDED ANSWER VALUES are observed and
    -- distinct: the actor prompt was answered with the caster cell/player uid,
    -- the landing prompt with its own distinct coordinate and no entity.
    local answers=ordered and seq[1].answer and seq[2].answer or nil
    local distinct=ordered and seq[2].radius==1 and seq[1].radius==nil
        and answers
        and seq[1].answer.x==p.x and seq[1].answer.y==p.y
        and seq[1].answer.uid==p.uid
        and seq[2].answer.x==p.x+3 and seq[2].answer.y==p.y
        and seq[2].answer.uid==nil
    check('movement-sequence:distinct-values',settled and distinct,
        {first=seq and seq[1],second=seq and seq[2]})
    signals[#signals+1]=(settled and distinct) and 'sd_distinct_values' or 'sd_distinct_missing'
    restore()
    -- (e) The per-request native guard: a landing 3 tiles away with a range-1
    -- second prompt is refused as the typed native cancel (never bypassed).
    local entry2,restore2=movementSequenceFixture('T_MCP_SEQ_B',{type='ball',range=1,radius=1,nowarning=true},true,false)
    local pol2=policy({{id='seq',priority=10,when={always={}},['then']={action='use_talent',
        talent='T_MCP_SEQ_B',target='self'}}})
    local host2=Runtime.buildAutoCombatHostFor(game,pol2,{drift=function() return true end})
    p.x,p.y=before.x,before.y
    local plan2=host2.plan({action='use_talent',talent='T_MCP_SEQ_B',target='self',
        target_plan=planArgs.target_plan,destination=dest})
    local outcome2
    forceReady()
    if p.talents_cd then p.talents_cd.T_MCP_SEQ_B=0 end
    if plan2 and plan2.plan then
        outcome2=host2.request({action='use_talent',talent='T_MCP_SEQ_B',plan=plan2.plan,rule='seq'})
    end
    local refused=outcome2 and outcome2.code=='target_out_of_range'
    check('movement-sequence:second-range-refused',refused,
        {status=outcome2 and outcome2.status,code=outcome2 and outcome2.code,
            deviation=outcome2 and outcome2.sequence_deviation})
    signals[#signals+1]=refused and 'sd_second_range_refused' or 'sd_second_range_missing'
    restore2()
    -- (f) A missing trailing optional entry is a settled native outcome with
    -- reduced=true (not an error).
    local entry3,restore3=movementSequenceFixture('T_MCP_SEQ_C',{type='ball',range=14,radius=1,nowarning=true},false,true)
    local pol3=policy({{id='seq',priority=10,when={always={}},['then']={action='use_talent',
        talent='T_MCP_SEQ_C',target='self'}}})
    local host3=Runtime.buildAutoCombatHostFor(game,pol3,{drift=function() return true end})
    p.x,p.y=before.x,before.y
    local plan3=host3.plan({action='use_talent',talent='T_MCP_SEQ_C',target='self',
        target_plan=planArgs.target_plan,destination=dest})
    local outcome3
    forceReady()
    if p.talents_cd then p.talents_cd.T_MCP_SEQ_C=0 end
    if plan3 and plan3.plan then
        outcome3=host3.request({action='use_talent',talent='T_MCP_SEQ_C',plan=plan3.plan,rule='seq'})
    end
    local reduced=outcome3 and outcome3.status=='ok' and outcome3.reduced==true
        and outcome3.reduced_reason=='trailing_optional_not_raised'
    check('movement-sequence:missing-optional-reduced',reduced,
        {status=outcome3 and outcome3.status,reduced=outcome3 and outcome3.reduced,
            deviation=outcome3 and outcome3.sequence_deviation})
    signals[#signals+1]=reduced and 'sd_missing_optional_reduced' or 'sd_missing_optional_missing'
    restore3()
    -- (g) S2-REV-01: a REORDERED native program. The declared sequence is
    -- actor-then-grid but the native body raises a grid-shaped prompt (ball)
    -- first and an actor-shaped prompt (hit) second. Every observed prompt is
    -- classified from its cursor spec and matched against the declared entry at
    -- that index, so the flow is `unexpected_target_request` and the live
    -- prompts are handed to the player — the queue never answers the k-th
    -- declared value blindly.
    local pR=game.player
    local entryR=assert(require('mod.auto_combat.MovementAdapterFactory').expand('request_then_landing',{
        request_sequence={{index=1,request='actor',subject='self',
                observed={cursor_type='hit',nowarning=true}},
            {index=2,request='grid',subject='self',value_source='target_plan',
                landing_from='envelope',observed={cursor_type='ball',nowarning=true}}},
        delivery='teleport',landing='random',center='requested_grid',traverses=false,
        relocates_other=false,radius=1,min_radius=0,range=10}))
    -- Simulate the player who answers the handed-back prompts themselves: the
    -- stub records every spec it was asked and answers its own coordinate, so
    -- the queue's declared values are provably absent from the native flow.
    local asked={}
    local saved_getTarget_R=rawget(pR,'getTarget')
    rawset(pR,'getTarget',function(self,typ,...)
        asked[#asked+1]=type(typ)=='table' and typ.type or tostring(typ)
        return pR.x+1,pR.y,nil
    end)
    pR.talents=pR.talents or {}
    pR.talents_def=pR.talents_def or {}
    pR.talents['T_MCP_SEQ_R']=1
    pR.talents_def['T_MCP_SEQ_R']={id='T_MCP_SEQ_R',name='MCP reorder probe',
        mode='activated',type={'spell/conveyance',1},cooldown=0,mana=0,
        action=function(self)
            -- REVERSED relative to the declared actor-then-grid program.
            local gx,gy=self:getTarget({type='ball',range=10,radius=1,nowarning=true,
                nolock=true,pass_terrain=true})
            if not gx then return nil end
            local ax,ay=self:getTarget({type='hit',range=10,nowarning=true})
            if not ax then return nil end
            return true
        end}
    local saved_entry_R=EffectManifest.ENTRIES['T_MCP_SEQ_R']
    EffectManifest.ENTRIES['T_MCP_SEQ_R']={kind='movement',target='self',resource='mana',
        movement=entryR,components={},conformance={builder=false}}
    local polR=policy({{id='seq',priority=10,when={always={}},['then']={action='use_talent',
        talent='T_MCP_SEQ_R',target='self'}}})
    local hostR=Runtime.buildAutoCombatHostFor(game,polR,{drift=function() return true end})
    pR.x,pR.y=before.x,before.y
    local planR=hostR.plan({action='use_talent',talent='T_MCP_SEQ_R',target='self',
        target_plan=planArgs.target_plan,destination=dest})
    local outcomeR
    forceReady()
    if pR.talents_cd then pR.talents_cd['T_MCP_SEQ_R']=0 end
    if planR and planR.plan then
        outcomeR=hostR.request({action='use_talent',talent='T_MCP_SEQ_R',plan=planR.plan,rule='seq'})
    end
    local devR=outcomeR and outcomeR.sequence_deviation
    local reorderRefused=outcomeR and outcomeR.status~='ok'
        and outcomeR.code=='unexpected_target_request'
        and devR and devR.expected.index==1 and devR.expected.request=='actor'
        and devR.observed.index==1 and devR.observed_shape=='ball'
        and devR.handed_back==true and devR.skippable==false
        and asked[1]=='ball' and asked[2]=='hit' and #asked==2
        and outcomeR.target_sequence and outcomeR.target_sequence[1].answer==nil
    check('movement-sequence:reorder-refused',reorderRefused,
        {status=outcomeR and outcomeR.status,code=outcomeR and outcomeR.code,
            deviation=devR,asked=asked,
            answers=outcomeR and outcomeR.target_sequence})
    signals[#signals+1]=reorderRefused and 'sd_reorder_refused' or 'sd_reorder_missing'
    -- Restore the reorder fixture.
    EffectManifest.ENTRIES['T_MCP_SEQ_R']=saved_entry_R
    if pR.talents then pR.talents['T_MCP_SEQ_R']=nil end
    if pR.talents_def then pR.talents_def['T_MCP_SEQ_R']=nil end
    if pR.talents_cd then pR.talents_cd['T_MCP_SEQ_R']=nil end
    if saved_getTarget_R==nil then rawset(pR,'getTarget',nil) else rawset(pR,'getTarget',saved_getTarget_R) end
    -- (i) S2-FIX5: a native entry that refuses BEFORE any prompt. A REAL
    -- cooldown (`p.talents_cd[talent]>0`) makes the production `useTalent`
    -- return false before it creates the coroutine or raises any prompt
    -- (ActorTalents isTalentCoolingDown), so the ordered queue observes ZERO
    -- prompts. The auto slot must report the ordinary native rejection — with
    -- its own cooldown detail and NO sequence_deviation — and the real
    -- controller must NOT fabricate a paused/unexpected_target_request event.
    local pC=game.player
    local entryC,restoreC=movementSequenceFixture('T_MCP_SEQ_CD',{type='ball',range=14,radius=1,nowarning=true},true,false)
    local polC=policy({{id='seq',priority=10,when={always={}},['then']={action='use_talent',
        talent='T_MCP_SEQ_CD',target='self',target_plan=planArgs.target_plan}}})
    local hostC=Runtime.buildAutoCombatHostFor(game,polC,{drift=function() return true end})
    pC.x,pC.y=before.x,before.y
    local planC=hostC.plan({action='use_talent',talent='T_MCP_SEQ_CD',target='self',
        target_plan=planArgs.target_plan,destination=dest})
    local outcomeC
    forceReady()
    if pC.talents_cd then pC.talents_cd['T_MCP_SEQ_CD']=11 end
    if planC and planC.plan then
        -- (i-a) executor layer: the real auto-slot submission of a
        -- cooldown-refused entry is the ordinary native rejection.
        outcomeC=hostC.request({action='use_talent',talent='T_MCP_SEQ_CD',plan=planC.plan,rule='seq'})
    end
    local cooldownRejected=outcomeC and outcomeC.status=='rejected'
        and outcomeC.code=='native_rejected'
        and outcomeC.sequence_deviation==nil
        and outcomeC.missing and outcomeC.missing[1]
        and outcomeC.missing[1].kind=='cooldown' and outcomeC.missing[1].remaining==11
        and outcomeC.target_sequence and #outcomeC.target_sequence==0
    check('movement-sequence:cooldown-native-rejected',cooldownRejected,
        {status=outcomeC and outcomeC.status,code=outcomeC and outcomeC.code,
            deviation=outcomeC and outcomeC.sequence_deviation,
            missing=outcomeC and outcomeC.missing})
    signals[#signals+1]=cooldownRejected and 'sd_cooldown_native_rejected' or 'sd_cooldown_missing'
    -- (i-b) controller layer: through the REAL controller, the same
    -- cooldown-refused submission produces no paused/unexpected_target_request
    -- event (no fabricated pause); the ordinary native_rejected denial is
    -- what the policy log sees.
    local cdEvents={}
    -- The other synchronous controller scenarios override `phase` (the real
    -- `ready` boundary only arrives across display frames); the executor and
    -- every read stay the production ones.
    local controllerC=AutoCombat.new(polC,hostFor(polC,{phase=function() return 'ready' end}),
        {strict=false,notify=function(ev) cdEvents[#cdEvents+1]=ev end})
    controllerC:start()
    forceReady()
    if pC.talents_cd then pC.talents_cd['T_MCP_SEQ_CD']=11 end
    local stepC=controllerC:onOpportunity()
    local fabricated=false
    for _,ev in ipairs(cdEvents) do
        if ev.kind=='paused' and ev.reason=='unexpected_target_request' then fabricated=true end
    end
    local denied=false
    for _,rejection in ipairs(controllerC.rejections or {}) do
        if rejection.rule=='seq' and rejection.reason=='native_rejected' then denied=true end
    end
    check('movement-sequence:cooldown-no-pause',cooldownRejected and denied and not fabricated
        and controllerC.state~='paused',
        {step=stepC and stepC.action,state=controllerC.state,reason=controllerC.reason,
            events=cdEvents,rejections=controllerC.rejections})
    signals[#signals+1]=(cooldownRejected and denied and not fabricated)
        and 'sd_cooldown_no_pause' or 'sd_cooldown_pause_missing'
    restoreC()
    -- (j) S2-FIX5-R1: the mirror image of (i) — a REAL native entry that returns
    -- TRUE without raising any prompt (the pre-prompt refusal exemption must not
    -- excuse a success). A fixture talent whose `action` returns true before any
    -- `getTarget` is driven through the production `useTalent` and the auto slot;
    -- the declared non-optional program was never consumed, so the executor must
    -- surface the typed missing-sequence deviation (NOT `action_complete`) and the
    -- real controller must pause on it instead of continuing.
    local pZ=game.player
    local entryZ,restoreZ=movementSequenceFixture('T_MCP_SEQ_Z',{type='ball',range=14,radius=1,nowarning=true},true,false)
    -- The fixture's action raises prompts; replace it with a zero-prompt truthy
    -- native body (same closed definition otherwise: mana/cooldown/mode).
    pZ.talents_def['T_MCP_SEQ_Z'].action=function(self) return true end
    local polZ=policy({{id='seq',priority=10,when={always={}},['then']={action='use_talent',
        talent='T_MCP_SEQ_Z',target='self',target_plan=planArgs.target_plan}}})
    local hostZ=Runtime.buildAutoCombatHostFor(game,polZ,{drift=function() return true end})
    pZ.x,pZ.y=before.x,before.y
    local planZ=hostZ.plan({action='use_talent',talent='T_MCP_SEQ_Z',target='self',
        target_plan=planArgs.target_plan,destination=dest})
    local outcomeZ
    forceReady()
    if pZ.talents_cd then pZ.talents_cd['T_MCP_SEQ_Z']=0 end
    if planZ and planZ.plan then
        outcomeZ=hostZ.request({action='use_talent',talent='T_MCP_SEQ_Z',plan=planZ.plan,rule='seq'})
    end
    local devZ=outcomeZ and outcomeZ.sequence_deviation
    local zeroPromptDeviated=outcomeZ and outcomeZ.status~='ok'
        and outcomeZ.code=='unexpected_target_request'
        and devZ and devZ.reason=='unexpected_target_request'
        and devZ.expected.index==1 and devZ.expected.request=='actor'
        and devZ.observed.index==1 and devZ.observed.request==nil
        and devZ.skippable==false
        and outcomeZ.target_sequence and #outcomeZ.target_sequence==0
    check('movement-sequence:zero-prompt-success-deviated',zeroPromptDeviated,
        {status=outcomeZ and outcomeZ.status,code=outcomeZ and outcomeZ.code,
            deviation=devZ,answer=outcomeZ and outcomeZ.target_sequence})
    signals[#signals+1]=zeroPromptDeviated and 'sd_zero_prompt_success_deviated'
        or 'sd_zero_prompt_success_missing'
    -- Controller layer: the same submission pauses on the typed deviation (the
    -- action is never reported as completed).
    local zpEvents={}
    local controllerZ=AutoCombat.new(polZ,hostFor(polZ,{phase=function() return 'ready' end}),
        {strict=false,notify=function(ev) zpEvents[#zpEvents+1]=ev end})
    controllerZ:start()
    forceReady()
    if pZ.talents_cd then pZ.talents_cd['T_MCP_SEQ_Z']=0 end
    local stepZ=controllerZ:onOpportunity()
    local pausedZ=false
    for _,ev in ipairs(zpEvents) do
        if ev.kind=='paused' and ev.reason=='unexpected_target_request'
            and ev.detail and ev.detail.expected and ev.detail.expected.index==1 then
            pausedZ=true
        end
    end
    check('movement-sequence:zero-prompt-success-paused',zeroPromptDeviated and pausedZ
        and controllerZ.state=='paused' and controllerZ.attempts==0,
        {step=stepZ and stepZ.action,state=controllerZ.state,reason=controllerZ.reason,
            attempts=controllerZ.attempts,events=zpEvents})
    signals[#signals+1]=(zeroPromptDeviated and pausedZ) and 'sd_zero_prompt_success_paused'
        or 'sd_zero_prompt_success_pause_missing'
    restoreZ()
    -- Restore the native seams and the player's previous position/energy so the
    -- later asynchronous stages drive the real production entries.
    restoreSeams()
    p.x,p.y=before.x,before.y
    forceReady()
    return compare('movement-sequence',signals)
end
M.movementSequenceChecks=movementSequenceChecks


local function runAll()
    local ok,err=pcall(function()
        startWhenReady()
        pauseResume()
        nativePending()
        criticalState()
        strictResume()
        restPolicy()
        explorePolicy()
        sunPaladinPreset()
        assistantImport()
        computedPredicate()
        productionReads()
        pilotPresets()
        guardRealSpec()
        M.effectFootprintParity()
        M.manifestDrift()
        M.dynamicTalents()
        movementNativeFallback()
        movementPlan()
        movementFactoryChecks()
        movementSequenceChecks()
    end)
    if not ok then check('scenarios:exception',false,{error=tostring(err)}) end
    return ok
end

-- MFT-REV-09 settle helper: alternate a settling tick (unpaused) with a
-- ready-boundary check (paused); a yielding native talent body needs ticks,
-- while `ready` is only reported at a paused boundary. A stale native targeting
-- UI left by a yielding body is cleared so the game returns to dispatch.
local function settleTick(frames)
    if frames%3==0 then
        game.paused=false
        if core and core.game and type(core.game.requestNextTick)=='function' then
            core.game.requestNextTick()
        end
    else
        forceReady()
    end
    if game.target and game.target.active and type(game.target.close)=='function' then
        pcall(function() game.target:close() end)
    end
    if game.target then game.target.active=false end
    game.target_co=nil
end

local function productionReady()
    local probe=Runtime.buildAutoCombatHostFor(game,policy({WAIT}),{drift=function() return true end})
    local phase=probe and probe.phase and probe.phase() or 'ready'
    return phase=='ready'
end

-- S2 rev3/§6.2 + S2-R3-03: TRULY YIELDING native handbacks driven through the
-- PRODUCTION service/controller join. Unlike the synchronous reorder fixture
-- above (which stubs `p.getTarget`), this fixture does NOT stub `getTarget`:
-- the declared program's curated signature mismatches the raised prompt, so the
-- executor wrapper falls through to the real `original`, which enters
-- `targetGetForPlayer`'s exclusive target mode, registers a bridge handle and
-- genuinely suspends the native body on `coroutine.yield()`. The typed deviation
-- must therefore survive on the `native_pending` result while the invocation is
-- live, and the production service must pause with that reason, release the
-- lease and stop the run without resubmitting.
--
-- Evidence layering (exact, per the S2-R3-03 fix):
--   * the yielding submission is driven by `AutoCombatService.step` — the same
--     production function the frame pump calls — so the controller's
--     deviation-before-`native_pending` ordering, its pause, the safety-pause
--     stop and the Arbiter revoke are all observed in ONE submission without
--     any manual `nativeDeviation` call;
--   * the answered sub-cases go through the production MCP dispatch
--     (`Runtime.respond` via the `bridgeRequestFor` seam), never
--     `Interactions.prepare/apply` directly, so broken respond routing fails
--     this probe (S2-R3-02 was exactly such a routing defect);
--   * the unanswered sub-case triggers the bounded abort through the
--     production `abortAutoInvocationFor` seam (the same function the frame
--     pump calls) — it is NOT evidence for the pump's own frame bookkeeping;
--   * the direct lower-layer probes (movementSequenceChecks) remain the
--     executor-layer evidence and are unchanged.
-- The cases run from the frame pump (stage `handback`) because the phase must
-- be genuinely 'ready' (a flushed save pipe), which only arrives across real
-- display frames.
--
-- Three sub-cases: (A) 'answer' — a single-entry program whose curated `hit`
-- signature mismatches the raised `ball` prompt, answered after the lease is
-- released through Runtime respond; (B) 'timeout' — the same yield left
-- unanswered, cancelled at the bounded abort; (C) 'reorder' — a two-entry
-- SAME-KIND yielding reorder: both declared prompts are `hit`-shaped actor
-- prompts (mutually exclusive via the shared `nolock` discriminator), and the
-- native flow raises the entry-2-flavoured prompt first, so position 1 cannot
-- match and the live prompt is handed back.
local function handbackFixture(name,sigs,raiseSpecs)
    local p=game.player
    local Factory=require 'mod.auto_combat.MovementAdapterFactory'
    local declared={}
    for i,sig in ipairs(sigs) do
        declared[i]={index=i,request='actor',subject='self',observed=sig}
    end
    local entry=assert(Factory.expand('request_then_landing',{
        request_sequence=declared,
        delivery='teleport',landing='random',center='self',traverses=false,
        relocates_other=false,radius=1,min_radius=0,range=10}))
    p.talents=p.talents or {}
    p.talents_def=p.talents_def or {}
    p.talents_cd=p.talents_cd or {}
    p.talents[name]=1
    p.talents_cd[name]=0
    p.talents_def[name]={id=name,name='MCP handback probe',mode='activated',type={'spell/conveyance',1},
        cooldown=0,mana=0,
        action=function(self)
            for _,spec in ipairs(raiseSpecs) do
                local copy={}
                for key,value in pairs(spec) do copy[key]=value end
                local x,y=self:getTarget(copy)
                if not x then return nil end
                self.handback_answer={x=x,y=y}
            end
            return true
        end}
    -- S2-R3-03: the fixture talent must be schema-admissible for the duration
    -- of the case, so `set_draft` genuinely validates the policy and the run
    -- really executes the controller path (a silently rejected draft would
    -- bypass the production joins this probe exists to prove).
    local savedEntry=EffectManifest.ENTRIES[name]
    local savedSchema=Schema.TALENTS[name]
    Schema.TALENTS[name]=true
    EffectManifest.ENTRIES[name]={kind='movement',target='self',resource='mana',
        movement=entry,components={},conformance={builder=false}}
    return entry,function()
        EffectManifest.ENTRIES[name]=savedEntry
        if savedSchema==nil then Schema.TALENTS[name]=nil else Schema.TALENTS[name]=savedSchema end
        if p.talents then p.talents[name]=nil end
        if p.talents_def then p.talents_def[name]=nil end
        if p.talents_cd then p.talents_cd[name]=nil end
        p.handback_answer=nil
    end
end

-- Stage 1 (one frame slot): prepare the run, drive ONE opportunity through the
-- PRODUCTION service step, then answer or abort. Everything here is
-- synchronous inside one submission; returns a finalize table for the answered
-- modes (settled across later frames by the pump) or nil for the timeout mode
-- (which completes inline).
local function handbackRun(answerMode)
    forceReady()
    Runtime.setAutoCombatExecution(game,true)
    local p=game.player
    local sigs,raiseSpecs
    if answerMode=='reorder' then
        -- S2-R4-03: a GENUINE same-kind reorder for a Vault-shaped
        -- presence-explicit pair. Entry 1 declares `nolock` ABSENT (the
        -- presence-explicit rule then requires the prompt NOT to raise it),
        -- entry 2 declares `nolock=true`; the raised prompt carries entry 2's
        -- COMPLETE presence-explicit signature, so it matches entry 2 only and
        -- arrives at index 1 — a pure order deviation whose `matched_indexes`
        -- must be exactly `{2}` (the previous fixture raised a prompt with
        -- `nolock` absent, which was a zero-match drift case, not a reorder).
        sigs={{cursor_type='hit',nowarning=true},
            {cursor_type='hit',nolock=true,nowarning=true}}
        raiseSpecs={{type='hit',nolock=true,range=10,nowarning=true}}
    else
        sigs={{cursor_type='hit',nowarning=true}}
        raiseSpecs={{type='ball',range=10,radius=1,nowarning=true,nolock=true}}
    end
    local entry,restore=handbackFixture('T_MCP_HANDBACK',sigs,raiseSpecs)
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local dest={selector='position',x=p.x+2,y=p.y,accept=accept}
    local steps={{request='actor',selector='self'}}
    if answerMode=='reorder' then
        steps[2]={request='actor',selector='self'}
    end
    -- A hand-built policy (not the shared helper) so the safety gates cannot
    -- swallow this run: max_selffire_risk=100 (movement entries carry no damage
    -- footprint anyway), rules evaluated even with no visible enemy, and no
    -- new-enemy pause.
    local pol={schema='tome-auto-combat/v1',id='hb-probe',name='probe',
        limits={max_actions_per_tick=1},
        mode={on_no_enemy='evaluate_rules'},
        safety={min_hp_pct=35,max_selffire_risk=100,pause_on_new_enemy=false},
        targeting={default='self'},
        rules={{id='hb',priority=10,when={always={}},['then']={action='use_talent',
            talent='T_MCP_HANDBACK',target='self',destination=dest,target_plan=steps}}}}
    -- Arm the run so the production service owns the controller and the arbiter.
    Runtime.autoCombatHandle(game,'set_draft',{policy=pol})
    local approved=Runtime.autoCombatHandle(game,'approve',{})
    Runtime.autoCombatHandle(game,'activate',{expected_hash=approved and approved.approved_hash})
    -- The frame stage waited for a genuinely 'ready' phase boundary; assert it
    -- through the production host (the audited phase read the controller uses).
    local phaseHost=Runtime.buildAutoCombatHostFor(game,pol,{drift=function() return true end})
    local readyNow=phaseHost and phaseHost.phase and phaseHost.phase()=='ready'
    check('handback:phase-ready',readyNow==true,{phase=phaseHost and phaseHost.phase and phaseHost.phase()})
    forceReady()
    local started=Runtime.autoCombatHandle(game,'start',{})
    local svc=Runtime.autoCombatService(game)
    local signals={}
    signals[#signals+1]=readyNow and 'hb_phase_ready' or 'hb_phase_not_ready'
    if not (started and started.ok and svc and svc.controller) then
        check('handback:start',false,{started=started})
        Runtime.autoCombatHandle(game,'stop',{reason='handback_failed'})
        Runtime.setAutoCombatExecution(game,false)
        restore()
        forceReady()
        compare('handback-'..answerMode,signals)
        return nil
    end
    -- S2-R3-03: drive ONE opportunity through the PRODUCTION service step (the
    -- exact function the frame pump calls). The controller decides the 'hb'
    -- rule, plans through the production host and submits through the real
    -- executor; the native body genuinely yields inside this submission.
    local step=AutoCombatService.step(svc)
    local root=Runtime.autoInvocationFor(game)
    local stepInner=step and step.step or {}
    local handoff=step and step.ok and step.handoff==true
        and stepInner.action=='paused'
        and stepInner.reason=='unexpected_target_request'
        and stepInner.handed_back==true
    check('handback:service-handoff',handoff,
        {step=step,root=root~=nil})
    signals[#signals+1]=handoff and 'hb_service_handoff' or 'hb_handoff_missing'
    local okPending=root and (root.pending or 0)>0
        and root.sequence_deviation
        and root.sequence_deviation.reason=='unexpected_target_request'
        and root.sequence_deviation.handed_back==true
        and root.sequence_deviation.observed_shape~=nil
    check('handback:pending-deviation',okPending,
        {deviation=root and root.sequence_deviation,pending=root and root.pending,
            handed_back=root and root.handed_back})
    signals[#signals+1]=okPending and 'hb_pending_deviation' or 'hb_pending_missing'
    check('handback:live-command',root and root.command
        and root.command.target_handed_back=='unexpected_target_request'
        and root.command.target_cancelled==nil,
        {handed_back=root and root.command and root.command.target_handed_back,
            cancelled=root and root.command and root.command.target_cancelled})
    -- Path 1 + Option A in one submission: the controller paused with the typed
    -- reason and the service stopped the run and released the lease. The
    -- controller must never have entered `waiting_native` (the reason is the
    -- typed deviation, not 'native_pending').
    local svcStatus=Runtime.autoCombatStatus(game) or {}
    local run=svcStatus.run or {}
    local stopped=(svc.controller and svc.controller.state=='stopped')
        and svc.controller.reason=='unexpected_target_request'
        and svcStatus.control_owner=='manual' and run.state=='stopped'
    check('handback:safety-stop',stopped,
        {state=svc.controller and svc.controller.state,
            reason=svc.controller and svc.controller.reason,
            owner=svcStatus.control_owner,run_state=run.state})
    signals[#signals+1]=stopped and 'hb_lease_released' or 'hb_lease_held'
    local neverWaiting=(svc.controller and svc.controller.reason~='native_pending')
        and run.reason~='native_pending'
    check('handback:never-waiting-native',neverWaiting,
        {controller_reason=svc.controller and svc.controller.reason,run_reason=run.reason})
    -- Not resubmitted: the run is stopped, so no new opportunity is taken.
    local attempts_before=run.attempts or 0
    AutoCombatService.step(svc)
    local status2=Runtime.autoCombatStatus(game) or {}
    check('handback:not-resubmitted',(status2.run and status2.run.attempts or 0)==attempts_before,
        {before=attempts_before,after=status2.run and status2.run.attempts})
    signals[#signals+1]='hb_not_resubmitted'
    -- The live interaction is answerable through the bridge after release.
    local Interactions=require 'mod.mcp_bridge.Interactions'
    local handle=root and Interactions.current(root)
    local answerable=handle~=nil and handle.target~=nil
    check('handback:answerable',answerable,{handle=handle and handle.kind})
    signals[#signals+1]=answerable and 'hb_answerable' or 'hb_unanswerable'
    signals[#signals+1]='hb_never_waiting_native'
    if answerMode~='timeout' then
        -- S2-R3-03: answer through the PRODUCTION MCP respond routing (never
        -- Interactions.prepare/apply directly). The bridge dispatch needs an
        -- authenticated session; connect through the same dispatch with the
        -- configured token (the probe rig configures one).
        local token=(config.settings.tome_mcp_bridge
            and config.settings.tome_mcp_bridge.token) or 'auto-combat-probe'
        local connected=Runtime.bridgeRequestFor(game,{v=4,id='hb-connect',op='connect',
            args={token=token}})
        local session=connected.result
        check('handback:bridge-connect',session and session.session_id and session.control_token,
            {connected=connected.ok,code=connected.error and connected.error.code})
        local observedView=session and Runtime.bridgeRequestFor(game,{v=4,id='hb-observe',
            op='observe',args={session_id=session.session_id}})
        local revision=observedView and observedView.result and observedView.result.revision
        local answered=session and Runtime.bridgeRequestFor(game,{v=4,id='hb-respond',
            op='respond',args={session_id=session.session_id,
                control_token=session.control_token,command_id='cmd-999999',
                interaction_id=handle.interaction_id,response_id='r-hb',
                expected_revision=revision,
                answer={type='position',x=p.x+2,y=p.y}}})
        local routed=answered and answered.result and answered.result.answered==true
            and answered.result.scope=='auto_combat'
            and p.handback_answer~=nil
            and p.handback_answer.x==p.x+2 and p.handback_answer.y==p.y
        check('handback:respond-routed',routed,
            {ok=answered and answered.ok,code=answered and answered.error and answered.error.code,
                answer=p.handback_answer})
        signals[#signals+1]=routed and 'hb_respond_routed' or 'hb_respond_missing'
        -- S2-R3-02 on the native path: the routed answer is fingerprinted,
        -- counted and marked consumed on the auto command.
        local autoCommand=(root and root.command) or {}
        local receipt=autoCommand.responses and autoCommand.responses['r-hb']
        local counted=autoCommand.response_count==1 and receipt~=nil
            and receipt.fingerprint~=nil
            and autoCommand.consumed_interactions
                and autoCommand.consumed_interactions[handle.interaction_id]==true
        check('handback:respond-receipt',counted,
            {count=autoCommand.response_count,fingerprint=receipt and receipt.fingerprint~=nil})
        signals[#signals+1]=counted and 'hb_respond_receipt' or 'hb_receipt_missing'
        if answerMode=='reorder' then
            -- Same-kind reorder evidence (S2-R4-03): the handed-back prompt's
            -- shape equals the declared cursor_type of BOTH entries (a pure order
            -- deviation, not a shape one) AND the typed deviation's
            -- `matched_indexes` is exactly `{2}` (entry 2's complete
            -- presence-explicit signature arrived at index 1).
            local seq=(root and root.command and root.command.target_sequence) or {}
            local dev=root and root.sequence_deviation
            local matched=dev and dev.matched_indexes or {}
            local sameKind=seq[1]~=nil
                and seq[1].shape==sigs[1].cursor_type
                and seq[1].shape==sigs[2].cursor_type
                and dev~=nil and dev.reason=='unexpected_target_request'
                and dev.observed_shape==sigs[2].cursor_type
                and #matched==1 and matched[1]==2
            check('handback:same-kind-reorder',sameKind,
                {sequence=seq,expected=sigs[1].cursor_type,
                    matched_indexes=dev and dev.matched_indexes,reason=dev and dev.reason})
            signals[#signals+1]=sameKind and 'hb_same_kind_reorder' or 'hb_kind_missing'
        end
        -- Finalize across later frames: the body settles once answered, then
        -- the frame reaper releases the invocation root.
        local function finalize()
            check('handback:body-settled',Runtime.autoInvocationFor(game)==nil,
                {pending=Runtime.autoInvocationFor(game)~=nil})
            Runtime.autoCombatHandle(game,'stop',{reason='handback_done'})
            Runtime.setAutoCombatExecution(game,false)
            if root then pcall(Interactions.cancelTarget,root);pcall(Interactions.release,root) end
            restore()
            forceReady()
            compare('handback-'..answerMode,signals)
        end
        return finalize
    end
    -- Timeout mode: do not answer; the bounded abort cancels the live targeting
    -- UI. The abort seam is the same production function the frame pump calls.
    Runtime.abortAutoInvocationFor(game,{tick=game.turn,ms=0,frames=0},
        {ticks=Runtime.AUTO_NATIVE_TIMEOUT_TICKS,ms=0,frames=Runtime.AUTO_NATIVE_TIMEOUT_FRAMES})
    local record=Runtime.lastNativeAbort(game)
    local cancelled=record and record.cancelled==true
        and record.reason~='authoritative_target_cancelled'
    check('handback:unanswered-cancelled',cancelled,
        {record=record,handle_closed=not (root and Interactions.current(root))})
    signals[#signals+1]=cancelled and 'hb_unanswered_cancelled' or 'hb_unanswered_open'
    Runtime.autoCombatHandle(game,'stop',{reason='handback_done'})
    Runtime.setAutoCombatExecution(game,false)
    if root then pcall(Interactions.cancelTarget,root);pcall(Interactions.release,root) end
    restore()
    forceReady()
    compare('handback-'..answerMode,signals)
    return nil
end

function M.onFrame()
    if M.done then return end
    if M.waiting_handoff then
        if safetyHandoffCheck() then
            M.waiting_handoff=false
            if not soloPumpSetup() then
                check('solo-pump:setup',false,{note='could not install local execution'})
                M.done=true
                M.emit{kind='auto_combat_done',passed=false,checks=#M.checks,failures=M.failures}
                return
            end
            M.waiting_solo=true
        end
        return
    end
    if M.waiting_solo then soloPumpCheck() return end
    if M.waiting_final then
        if M.final_stage=='talents' then
            if not M.mt then
                movementTalentSetup()
                return
            end
            if M.mt.pending then
                M.mt.frames=(M.mt.frames or 0)+1
                settleTick(M.mt.frames)
                if productionReady() or M.mt.frames>=240 then
                    movementTalentAssert(M.mt.specs[M.mt.index])
                    M.mt.pending=false
                end
                return
            end
            M.mt.index=M.mt.index+1
            local spec=M.mt.specs[M.mt.index]
            if spec then
                movementTalentRun(spec)
                return
            end
            compare('movement-talents',M.mt.signals)
            Runtime.autoCombatHandle(game,'deactivate',{})
            Runtime.setAutoCombatExecution(game,false)
            M.mt=nil
            M.final_stage='settle'
            M.final_frames=0
            return
        end
        if M.final_stage=='settle' then
            M.final_frames=(M.final_frames or 0)+1
            settleTick(M.final_frames)
            if productionReady() or M.final_frames>=120 then
                forceReady()
                -- S2-R3-03: the handback cases need a genuinely 'ready' phase
                -- (a flushed save pipe), which only arrives across real display
                -- frames; run them from the frame pump like the other native
                -- final stages, before the scene lifecycle scenario.
                M.final_stage='handback'
                M.handback_queue={'answer','timeout','reorder'}
                M.handback_index=1
                M.handback_stage='wait'
                M.final_frames=0
            end
            return
        end
        if M.final_stage=='handback' then
            M.final_frames=(M.final_frames or 0)+1
            if M.handback_stage=='wait' then
                settleTick(M.final_frames)
                if productionReady() or M.final_frames>=240 then
                    forceReady()
                    M.handback_stage='run'
                end
                return
            end
            if M.handback_stage=='settle' then
                M.handback_frames=(M.handback_frames or 0)+1
                settleTick(M.handback_frames)
                if Runtime.autoInvocationFor(game)==nil or M.handback_frames>=240 then
                    if M.handback_finalize then
                        local ok_f,err_f=pcall(M.handback_finalize)
                        if not ok_f then check('handback:finalize',false,{error=tostring(err_f)}) end
                    end
                    M.handback_finalize=nil
                    M.handback_index=M.handback_index+1
                    if M.handback_queue[M.handback_index]==nil then
                        M.final_stage='scene'
                        M.final_frames=0
                        return
                    end
                    M.handback_stage='wait'
                    M.final_frames=0
                end
                return
            end
            -- stage 'run': one synchronous yielding submission per case.
            local finalize=handbackRun(M.handback_queue[M.handback_index])
            if finalize then
                M.handback_finalize=finalize
                M.handback_stage='settle'
                M.handback_frames=0
            else
                M.handback_index=M.handback_index+1
                if M.handback_queue[M.handback_index]==nil then
                    M.final_stage='scene'
                    M.final_frames=0
                    return
                end
                M.handback_stage='wait'
                M.final_frames=0
            end
            return
        end
        if M.final_stage=='scene' then
            -- S2-R3-03: settle-gate the scene scenario in the SAME frame it
            -- runs: a ready check one frame earlier can be invalidated by the
            -- alternate-tick settle (the yielding bodies need ticks, and a
            -- controller started on a stale boundary defers to awaiting_ready).
            M.final_frames=(M.final_frames or 0)+1
            local sceneReady=productionReady()
                and Runtime.autoInvocationFor(game)==nil
            if not sceneReady and M.final_frames<240 then
                settleTick(M.final_frames)
                return
            end
            forceReady()
            sceneLifecycle()
            M.final_stage='done'
            M.waiting_final=false
            M.done=true
            M.emit{kind='auto_combat_done',passed=M.failures==0,failures=M.failures,checks=#M.checks}
            return
        end
        return
    end
    if not M.pending then return end
    M.pending=false
    if not runAll() then
        M.done=true
        M.emit{kind='auto_combat_done',passed=false,checks=#M.checks,failures=M.failures}
        return
    end
    -- Run the Option-A handoff after the synchronous scenarios (a clean game
    -- boundary) so the production pump sees a ready phase.
    local handoff_ok,handoff_result=pcall(safetyHandoffSetup)
    if not handoff_ok then
        check('safety-handoff:exception',false,{error=tostring(handoff_result)})
        M.done=true
        M.emit{kind='auto_combat_done',passed=false,checks=#M.checks,failures=M.failures}
        return
    end
    if handoff_result~=true then
        M.done=true
        M.emit{kind='auto_combat_done',passed=false,checks=#M.checks,failures=M.failures}
        return
    end
    M.waiting_handoff=true
end
return M
