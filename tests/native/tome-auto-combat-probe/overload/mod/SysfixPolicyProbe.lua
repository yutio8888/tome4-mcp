-- SYSFIX policy probes. Every submission delegates to the production Runtime
-- host and Actions/NativeActivity; no request outcome is injected. Player HP,
-- known talents/cooldowns and the rest predicate are test fixture setup only.
local Runtime=require 'mod.mcp_bridge.Runtime'
local Service=require 'mod.auto_combat.AutoCombatService'
local Json=require 'mod.mcp_bridge.Json'
local M={pending=false,checks={},failures=0,index=0,frames=0}
local CASES={'wait_cap','emergency_release','emergency_fallback','submission_cap','sustain_instant','pending_rest'}
local function emit(record) print('[AutoCombatProbe] '..Json.encode(record)) end
local function check(name,passed,details)
    local row={kind='auto_combat_check',name='sysfix:'..name,passed=passed==true,details=details}
    M.checks[#M.checks+1]=row
    if not passed then M.failures=M.failures+1 end
    emit(row)
end
local function rule(id,action,emergency)
    return {id=id,priority=emergency and 100 or 10,emergency=emergency,
        when={always={}},['then']=action}
end
local function policy()
    return {schema='tome-auto-combat/v1',id='sysfix-native',name='SYSFIX native',
        mode={on_low_hp='emergency_only',on_emergency_unavailable='release_control',on_new_enemy='continue'},
        limits={max_actions_per_tick=1,max_consecutive_actions=1},safety={min_hp_pct=35},
        rules={rule('wait',{action='wait'})}}
end
local function tick()
    game.paused=false
    if core and core.game and core.game.requestNextTick then core.game.requestNextTick() end
end
local function view()
    local host=Runtime.buildAutoCombatHostFor(game,policy())
    return host and host.phase(),host and host.opportunity_id()
end
local function recordHost(svc)
    local host=svc.controller.host
    local request=host.request
    local calls={}
    host.request=function(attempt)
        local outcome=request(attempt)
        calls[#calls+1]={rule=attempt.rule,action=attempt.action,run_id=attempt.run_id,
            submission_id=attempt.submission_id,generation=attempt.generation,
            status=outcome.status,energy_spent=outcome.energy_spent,instant=outcome.instant,
            code=outcome.code,missing=outcome.missing}
        return outcome
    end
    return calls
end
local function install(pol)
    local svc=Runtime.autoCombatService(game)
    local d=Service.setDraft(svc,pol)
    assert(d.ok,Json.encode(d))
    assert(Service.approve(svc,d.draft_hash).ok)
    assert(Service.activate(svc).ok)
    local started=Service.start(svc)
    assert(started.ok,Json.encode(started))
    local calls=recordHost(svc)
    return svc,calls,svc.controller.generation
end
local function stopped(svc,reason,generation)
    local status=Service.status(svc)
    return status.run and status.run.state=='stopped' and status.run.reason==reason
        and status.control_owner=='manual' and status.run.generation==generation+1
end
local function finish()
    if M.restore then M.restore(); M.restore=nil end
    local svc=Runtime.autoCombatService(game)
    if svc then Service.stop(svc,'probe_case_complete') end
    local _,oid=view(); M.previous_oid=oid
    M.current=nil; M.frames=0; tick()
end
local function runCase(name)
    local p=game.player
    p.life=p.max_life
    local pol=policy()
    if name=='wait_cap' then
        local svc,calls,gen=install(pol)
        local before=p.energy.value
        local result=Service.step(svc)
        check(name,stopped(svc,'max_consecutive_actions',gen) and #calls==1
            and calls[1].status=='ok' and svc.controller.actions==1,
            {step=result,run=svc.controller:status(),calls=calls,energy_before=before,energy_after=p.energy.value})
        local count=#calls
        Service.start(svc); Service.step(svc)
        check('same_opportunity_restart',#calls==count and svc.controller.native_submissions==1
            and svc.controller.actions==0,{run=svc.controller:status()})
        finish()
    elseif name=='emergency_release' or name=='emergency_fallback' or name=='submission_cap' then
        if not p:knowTalent('T_HEALING_LIGHT') then p:learnTalent('T_HEALING_LIGHT',true) end
        p.life=p.max_life*0.30
        p.talents_cd=p.talents_cd or {}
        local old=p.talents_cd.T_HEALING_LIGHT
        p.talents_cd.T_HEALING_LIGHT=10
        M.restore=function() p.talents_cd.T_HEALING_LIGHT=old; p.life=p.max_life end
        pol.rules={rule('heal',{action='use_talent',talent='T_HEALING_LIGHT',target='self'},true),
            rule('wait',{action='wait'})}
        if name=='emergency_fallback' then pol.mode.on_emergency_unavailable='evaluate_rules' end
        if name=='submission_cap' then pol.limits.max_consecutive_actions=200 end
        local svc,calls,gen=install(pol)
        local result=Service.step(svc)
        if name=='submission_cap' then
            local allCalls=calls
            for _=2,32 do
                assert(Service.start(svc).ok)
                calls=recordHost(svc); gen=svc.controller.generation
                result=Service.step(svc)
                for _,call in ipairs(calls) do allCalls[#allCalls+1]=call end
            end
            local rejected=#allCalls==32
            for _,call in ipairs(allCalls) do
                rejected=rejected and call.status=='rejected' and call.energy_spent==false
            end
            check(name,rejected and stopped(svc,'native_submission_limit',gen)
                and svc.controller.native_submissions==32 and svc.controller.actions==0,
                {step=result,run=svc.controller:status(),calls=allCalls})
            assert(Service.start(svc).ok)
            local cappedCalls=recordHost(svc)
            Service.step(svc)
            check('submission_cap_restart',#cappedCalls==0 and svc.controller.native_submissions==32,
                {run=svc.controller:status(),calls=cappedCalls})
        elseif name=='emergency_release' then
            check(name,stopped(svc,'action_denied',gen) and #calls==1 and calls[1].rule=='heal'
                and calls[1].status=='rejected' and svc.controller.actions==0,
                {step=result,run=svc.controller:status(),calls=calls})
        else
            check(name,stopped(svc,'max_consecutive_actions',gen) and #calls==2
                and calls[1].status=='rejected' and calls[2].rule=='wait' and calls[2].status=='ok'
                and svc.controller.actions==1 and svc.controller.attempts==1,
                {step=result,run=svc.controller:status(),calls=calls})
        end
        finish()
    elseif name=='sustain_instant' then
        if not p:knowTalent('T_CHANT_OF_FORTRESS') then p:learnTalent('T_CHANT_OF_FORTRESS',true) end
        if p:isTalentActive('T_CHANT_OF_FORTRESS') then
            p:forceUseTalent('T_CHANT_OF_FORTRESS',{ignore_energy=true})
        end
        p.talents_cd.T_CHANT_OF_FORTRESS=nil
        if p.max_positive then p.positive=p.max_positive end
        pol.sustains={{talent='T_CHANT_OF_FORTRESS',priority=10}}
        local svc,calls,gen=install(pol)
        local result=Service.step(svc)
        check(name,stopped(svc,'max_consecutive_actions',gen) and #calls==1
            and calls[1].action=='set_sustain' and calls[1].status=='ok' and calls[1].instant==true
            and svc.controller.instant_attempts==1 and svc.controller.actions==1,
            {step=result,run=svc.controller:status(),calls=calls})
        finish()
    elseif name=='pending_rest' then
        p.life=p.max_life*0.5
        local old=p.restCheck
        p.restCheck=function() return true end
        M.restore=function() p.restCheck=old; p.life=p.max_life end
        pol.rules={rule('rest',{action='rest',max_turns=2})}
        local svc,calls,gen=install(pol)
        local result=Service.step(svc)
        check('pending_rest_submitted',#calls==1 and calls[1].status=='native_pending'
            and result.step.action=='wait_native' and svc.controller.actions==0,
            {step=result,run=svc.controller:status(),calls=calls})
        M.waiting={svc=svc,calls=calls,generation=gen}
        -- Run the native bounded activity to a real progressed terminal; a
        -- zero-progress cancellation is correctly a rejection, not success.
        tick()
    end
end
function M.onFrame()
    if M.done then return end
    if not M.started then
        if not M.pending then return end
        M.pending=false; M.started=true
        Runtime.setAutoCombatExecution(game,true)
        local svc=Runtime.autoCombatService(game)
        Service.stop(svc,'probe_initialise')
    end
    M.frames=M.frames+1
    if M.waiting then
        local w=M.waiting
        if w.svc.controller and w.svc.controller.pending_attempt==nil then
            check('pending_rest_settled',#w.calls==1 and stopped(w.svc,'max_consecutive_actions',w.generation)
                and w.svc.controller.actions==1,
                {run=w.svc.controller:status(),calls=w.calls,log=Service.log(w.svc,6)})
            M.waiting=nil; finish()
        elseif M.frames>240 then
            check('pending_rest_settled',false,{reason='settlement_timeout',calls=w.calls})
            M.waiting=nil; finish()
        else
            tick()
        end
        return
    end
    if M.current==nil then
        local phase,oid=view()
        if phase~='ready' or (M.previous_oid~=nil and oid==M.previous_oid) then
            if M.frames>360 then
                check('ready_boundary',false,{phase=phase,oid=oid,previous_oid=M.previous_oid})
                M.done=true
            else tick(); return end
        else
            M.index=M.index+1
            M.current=CASES[M.index]
            if M.current then
                local ok,err=pcall(runCase,M.current)
                if not ok then check(M.current,false,{error=tostring(err)}); finish() end
                return
            end
            M.done=true
        end
    end
    if M.done then
        Runtime.setAutoCombatExecution(game,false)
        emit{kind='auto_combat_done',passed=M.failures==0,failures=M.failures,checks=#M.checks,
            suite='sysfix-policy',cases=#CASES}
    end
end
return M
