-- SYSFIX policy probes. Every submission delegates to the production Runtime
-- host and Actions/NativeActivity; no request outcome is injected. Player HP,
-- known talents/cooldowns and the rest predicate are test fixture setup only.
local Runtime=require 'mod.mcp_bridge.Runtime'
local Service=require 'mod.auto_combat.AutoCombatService'
local Json=require 'mod.mcp_bridge.Json'
local Codec=require 'mod.auto_combat.PolicyCodec'
local PolicyIO=require 'mod.auto_combat.PolicyIO'
local M={pending=false,checks={},failures=0,index=0,frames=0}
local CASES={'wait_cap','emergency_release','emergency_fallback','submission_cap','sustain_instant',
    'pending_rest','migration_archive','import_integrity'}
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
local function waitingDetails(w,reason)
    local phase,oid=view()
    return {reason=reason,calls=w.calls,run=Service.status(w.svc).run,
        submitted_run=w.controller:status(),controller_retained=w.svc.controller==w.controller,
        pending=w.controller.pending_attempt~=nil,phase=phase,opportunity=oid,
        turn_started=w.turn_started,world_tick=game.turn,frames=M.frames,
        rest_handle_observed=w.native_rest~=nil,
        rest_live=w.native_rest~=nil and game.player.resting==w.native_rest,
        rest_turns=w.native_rest and w.native_rest.cnt,
        energy=game.player.energy.value,paused=game.paused,log=Service.log(w.svc,6)}
end
-- These scenarios exercise the loaded source/package's real Service data
-- paths. saveState roundtrips are not engine savefile/restart evidence.
local function migrationCase()
    local svc=Runtime.autoCombatService(game)
    local before=Service.saveState(svc)
    M.restore=function() Service.loadState(svc,before) end
    local draft=policy(); draft.id='native-original-draft'; draft.updated='draft metadata'
    draft.mode.on_emergency_unavailable=nil; draft.rules[1].priority=31
    local approved=policy(); approved.id='native-original-approved'; approved.updated='approval metadata'
    approved.mode.on_emergency_unavailable=nil; approved.rules[1].priority=43
    local draftBytes=assert(Codec.encode(draft))
    local approvedBytes=assert(Codec.encode(approved))
    local migrated=Json.decode(Json.encode(approved)); migrated.mode.on_emergency_unavailable='release_control'
    local migratedBytes=assert(Codec.encode(migrated))
    local saved={format=2,draft=draft,approved=approved}
    for round=1,3 do
        assert(Service.loadState(svc,saved))
        local got=Service.get(svc)
        local previous=got.migration and got.migration.previous_draft
        local original=got.migration and got.migration.original_approved
        local previousBytes=previous and Codec.encode(previous)
        local originalBytes=original and Codec.encode(original)
        local activate=Service.activate(svc)
        check('migration_originals_round'..round,previousBytes==draftBytes and originalBytes==approvedBytes
            and Codec.encode(got.draft)==migratedBytes and got.migration.requires_reapproval==true
            and got.approved==nil and got.running==nil and got.active==false
            and activate.ok==false and activate.error.code=='not_approved',
            {round=round,expected_draft=draftBytes,previous_draft=previousBytes,
                expected_approved=approvedBytes,original_approved=originalBytes,
                requires_reapproval=got.migration and got.migration.requires_reapproval,activate=activate})
        saved=Json.decode(Json.encode(Service.saveState(svc)))
    end
end
local function importCase()
    local svc=Runtime.autoCombatService(game)
    local before=Json.encode{saved=Service.saveState(svc),versions=Service.get(svc),status=Service.status(svc)}
    local function unchanged()
        return before==Json.encode{saved=Service.saveState(svc),versions=Service.get(svc),status=Service.status(svc)}
    end
    local exported=assert(PolicyIO.export(policy()))
    for _,case in ipairs{{name='missing'},{name='null',hash=Json.null},{name='numeric',hash=42},{name='empty',hash=''}} do
        local data=Json.decode(exported); data.hash=case.hash
        local result=Service.import(svc,Json.encode(data))
        local same=unchanged()
        check('import_hash_'..case.name,result.ok==false and result.error.code=='invalid_document'
            and result.error.details.input=='hash' and same,{result=result,store_unchanged=same})
    end
    local mismatch=Json.decode(exported); mismatch.hash='mismatching-nonempty-hash'
    local rejected=Service.import(svc,Json.encode(mismatch))
    check('import_hash_mismatch',rejected.ok==false and rejected.error.code=='hash_mismatch' and unchanged(),
        {result=rejected,store_unchanged=unchanged()})
    local valid=Service.import(svc,exported)
    check('import_hash_valid',valid.ok==true and valid.hash==valid.original_hash and unchanged(),
        {result=valid,store_unchanged=unchanged()})
    local legacy=policy(); legacy.mode.on_emergency_unavailable=nil
    local hash=assert(Codec.prepare(legacy)).hash
    local envelope={format=PolicyIO.FORMAT,envelope=PolicyIO.ENVELOPE,policy=legacy,hash=hash}
    local migrated=Service.import(svc,Json.encode(envelope))
    check('import_legacy_original_hash',migrated.ok==true and migrated.original_hash==hash and migrated.hash~=hash
        and migrated.policy.mode.on_emergency_unavailable=='release_control' and #migrated.warnings>0 and unchanged(),
        {result=migrated,store_unchanged=unchanged()})
    envelope.hash=migrated.hash
    local wrong=Service.import(svc,Json.encode(envelope))
    check('import_legacy_migrated_hash',wrong.ok==false and wrong.error.code=='hash_mismatch' and unchanged(),
        {result=wrong,store_unchanged=unchanged()})
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
        M.waiting={svc=svc,controller=svc.controller,calls=calls,generation=gen,
            native_rest=p.resting,turn_started=game.turn}
        -- Run the native bounded activity to a real progressed terminal; a
        -- zero-progress cancellation is correctly a rejection, not success.
        tick()
    elseif name=='migration_archive' then
        migrationCase(); finish()
    elseif name=='import_integrity' then
        importCase(); finish()
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
        if w.svc.controller~=w.controller then
            check('pending_rest_settled',false,waitingDetails(w,'terminal_state_lost'))
            M.waiting=nil; finish()
        elseif w.controller.pending_attempt==nil then
            check('pending_rest_settled',#w.calls==1 and stopped(w.svc,'max_consecutive_actions',w.generation)
                and w.controller.actions==1 and w.controller.attempts==1 and w.controller.native_submissions==1
                and w.native_rest and w.native_rest.cnt==2 and game.player.resting~=w.native_rest,
                waitingDetails(w))
            M.waiting=nil; finish()
        elseif M.frames>240 then
            check('pending_rest_settled',false,waitingDetails(w,'settlement_timeout'))
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
