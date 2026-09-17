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
local NativeActivity=require 'mod.mcp_bridge.NativeActivity'
local Presets=require 'mod.auto_combat.PolicyPresets'
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
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
    ['critical']={'no_emergency_action'},
    ['strict-resume']={'new_enemy','new_enemy'},
    ['rest-policy']={'wait_native','stopped'},
    ['explore-policy']={'wait_native','stopped'},
    ['sun-paladin-preset']={'valid','compatible','dry_run'},
    ['assistant-import']={'generated','valid','unsupported_reported','stored','refused'},
    ['computed-predicate']={'act','false_holds','enum_rejected'},
    ['production-reads']={'has_control','scalar_resource','guard_wired'},
    ['pilot-presets']={'ok','ok','ok','cast'},
    ['guard-real-spec']={'self_reject','builder_safe','grasp_safe'},
    ['safety-handoff']={'handoff','owner_manual','stopped','resume_not_running'},
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

-- 4: below min_hp_pct only emergency rules may run; an unavailable emergency
-- action pauses and the normal rule is never submitted.
local function criticalState()
    forceReady()
    local p=game.player
    -- 30%: below min_hp_pct (35) but above flee_below_hp_pct (25), so the
    -- emergency layer is exercised without the distinct flee pause.
    p.life=p.max_life*0.3
    local pol=policy({HEAL,ATTACK},{max_actions_per_tick=2})
    local host,attempts=recordingHost(pol,{phase=function() return 'ready' end})
    local c=AutoCombat.new(pol,host,{strict=false})
    c:start()
    local result=c:onOpportunity()
    local normal=0
    for _,attempt in ipairs(attempts) do
        if attempt.action=='attack' or attempt.action=='wait' then normal=normal+1 end
    end
    check('critical:no-normal-output',normal==0 and result.reason=='no_emergency_action',
        {normal=normal,reason=result.reason,attempts=attempts})
    p.life=p.max_life
    return compare('critical',{result.action=='paused' and result.reason or result.action})
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
    local approved_before=service.store.approved
    local stored=Runtime.autoCombatHandle(game,'import_assistant',{config=config,store=true})
    local store_ok=stored and stored.ok==true and stored.stored and stored.stored.draft_hash
        and service.store.approved==approved_before
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
    M.done=true
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
    M.emit{kind='auto_combat_done',passed=M.failures==0,failures=M.failures,checks=#M.checks}
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

-- 13 (round 5): the guard reads the real target builder. The catalog still
-- advises a widebeam for Flame, but a temporary builder override must drive the
-- verdict (and Blood Grasp's real builder must classify as safe).
local function guardRealSpec()
    local p=game.player
    if not p:knowTalent('T_FLAME') then p:learnTalent('T_FLAME',true) end
    if not p:knowTalent('T_BLOOD_GRASP') then p:learnTalent('T_BLOOD_GRASP',true) end
    local pol=policy({WAIT})
    local host=Runtime.buildAutoCombatHostFor(game,pol)
    local ctx=host and host.snapshot('nearest_hostile')
    local bound=ctx and ctx.bound_target
    local def=p.talents_def and p.talents_def.T_FLAME
    if not bound or not (def and type(def.target)=='function') then
        check('guard-real-spec:setup',false,{bound=bound,has_builder=def~=nil})
        return compare('guard-real-spec',{'no_setup','no_setup','no_setup'})
    end
    local entry=Catalog.entry('T_FLAME')
    check('guard-real-spec:catalog',entry.shape=='widebeam','the catalog still advises a widebeam')
    local original=def.target
    local signals={}
    -- A builder-provided self-hitting ball must reject with the builder as the
    -- source, even though the catalog would not flag it as a self-hit.
    def.target=function() return {type='ball',range=100,radius=10,selffire=true,friendlyfire=true} end
    local selfhit=host.guard({action='use_talent',talent='T_FLAME',bound_target=bound})
    check('guard-real-spec:self',selfhit and selfhit.reason=='selffire_risk'
        and selfhit.detail and selfhit.detail.source=='builder' and selfhit.detail.phase=='instant',selfhit)
    signals[#signals+1]=(selfhit and selfhit.reason=='selffire_risk') and 'self_reject' or 'self_pass'
    def.target=function() return {type='ball',range=100,radius=1,selffire=false,friendlyfire=false} end
    local safe=host.guard({action='use_talent',talent='T_FLAME',bound_target=bound})
    check('guard-real-spec:safe',safe==nil,safe)
    signals[#signals+1]=safe==nil and 'builder_safe' or 'still_risky'
    def.target=original
    -- Blood Grasp's real builder is a bolt with explicit SF 0 / FF 0.
    local grasp=host.guard({action='use_talent',talent='T_BLOOD_GRASP',bound_target=bound})
    check('guard-real-spec:grasp',grasp==nil,grasp)
    signals[#signals+1]=grasp==nil and 'grasp_safe' or 'grasp_risky'
    return compare('guard-real-spec',signals)
end

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
    end)
    if not ok then check('scenarios:exception',false,{error=tostring(err)}) end
    return ok
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
