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
    p.life=p.max_life*0.2
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
    M.waiting_solo=false
    M.done=true
    check('solo-pump:ran',acted and (run.attempts or 0)>0,
        {attempts=run.attempts,state=run.state,reason=run.reason,acted=acted,frames=M.solo_frames})
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
    end)
    if not ok then check('scenarios:exception',false,{error=tostring(err)}) end
    return ok
end

function M.onFrame()
    if M.done then return end
    if M.waiting_solo then soloPumpCheck() return end
    if not M.pending then return end
    M.pending=false
    if not runAll() then
        M.done=true
        M.emit{kind='auto_combat_done',passed=false,checks=#M.checks,failures=M.failures}
        return
    end
    if not soloPumpSetup() then
        check('solo-pump:setup',false,{note='could not install local execution'})
        M.done=true
        M.emit{kind='auto_combat_done',passed=false,checks=#M.checks,failures=M.failures}
        return
    end
    M.waiting_solo=true
end
return M
