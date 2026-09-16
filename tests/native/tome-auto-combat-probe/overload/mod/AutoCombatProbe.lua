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
