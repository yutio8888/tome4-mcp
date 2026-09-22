-- POLICY-01/02/03 + SETTLEMENT-01 production service/controller regressions.
-- Engine-independent host outcomes are explicit doubles; native probes are a
-- separate evidence layer and never inferred from these checks.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
assert(root,'invoke with the addon path, not a bare test filename')
package.path=root..'/overload/?.lua;'..package.path
local Service=require 'mod.auto_combat.AutoCombatService'
local Combat=require 'mod.auto_combat.AutoCombat'
local Schema=require 'mod.auto_combat.PolicySchema'
local Codec=require 'mod.auto_combat.PolicyCodec'
local Store=require 'mod.auto_combat.PolicyStore'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(v,m) checks=checks+1; assert(v,m) end
local function eq(a,b,m) check(a==b,(m or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local function rule(id,emergency,action)
    return {id=id,priority=emergency and 100 or 10,emergency=emergency,
        when={always={}},['then']=action or {action='wait'}}
end
local function policy(limits)
    return {schema=Schema.SCHEMA,id='sysfix',name='System review regression',
        mode={on_low_hp='emergency_only',on_emergency_unavailable='release_control'},
        safety={min_hp_pct=35},limits=limits or {max_actions_per_tick=1},
        rules={rule('ordinary')}}
end
local function host()
    local h={oid=1,hp=80,requests={},outcome={status='ok',energy_spent=true}}
    h.phase=function() return h.phase_ or 'ready' end
    h.opportunity_id=function() return h.oid end
    h.enemy_ids=function() return {} end
    h.snapshot=function() return {hp_pct=h.hp,enemy_count=1} end
    h.request=function(a)
        h.requests[#h.requests+1]=a
        if h.execute then return h.execute(a) end
        return h.outcome
    end
    return h
end
local function service(p,h)
    local svc=Service.new{strict=false,host_factory=function() return h end}
    check(Schema.validate(p),'test policy is schema-valid')
    check(Service.setDraft(svc,p).ok,'set draft through production service')
    check(Service.approve(svc).ok,'approve through production store')
    check(Service.activate(svc).ok,'activate through production arbiter')
    check(Service.start(svc).ok,'start through production controller')
    return svc
end
local function settle(svc,h,fields,index)
    local a=h.requests[index or #h.requests]
    local out={run_id=a.run_id,submission_id=a.submission_id,generation=a.generation,
        status='ok',energy_spent=true}
    for k,v in pairs(fields or {}) do out[k]=v end
    return Service.nativeSettled(svc,out),out
end
local function terminal(svc,reason,generation,requests,h)
    local st=Service.status(svc)
    eq(st.run.state,'stopped','terminal run state')
    eq(st.run.reason,reason,'typed terminal reason')
    eq(st.control_owner,'manual','terminal releases lease')
    eq(st.run.generation,generation+1,'one terminal generation transition')
    eq(#h.requests,requests,'exact native request count')
    Service.stop(svc,reason)
    eq(svc.controller.generation,generation+1,'same-reason stop is idempotent')
end

-- A cap of one includes wait, movement, native activities and declared sustain.
for _,kind in ipairs{'wait','move','rest','auto_explore','sustain'} do
    local p=policy{max_actions_per_tick=4,max_consecutive_actions=1}
    local h=host()
    if kind=='sustain' then
        p.sustains={{talent='T_CHANT_OF_FORTRESS',priority=1}}
        h.sustain_on=function() return false end
        h.talent_known=function() return true end
    elseif kind=='move' then
        p.rules={rule('ordinary',false,{action='move',direction=6})}
        h.plan=function() return {plan={kind='step',direction=6,x=2,y=1}} end
    else p.rules={rule('ordinary',false,{action=kind})} end
    local svc=service(p,h); local generation=svc.controller.generation
    local step=Service.step(svc)
    eq(step.step.action,'stopped','cap terminates upon first effective action: '..kind)
    terminal(svc,'max_consecutive_actions',generation,1,h)
    eq(Service.status(svc).run.run_actions,1,'run counter counts native action: '..kind)
    h.oid=2; Service.step(svc)
    eq(#h.requests,1,'a new opportunity cannot bypass terminal cap')
end

-- A mixed run retains cap and opportunity accounting across pause/resume;
-- success OR energy_spent counts once, even when both are true.
do
    local p=policy{max_actions_per_tick=4,max_consecutive_actions=3}
    p.sustains={{talent='T_CHANT_OF_FORTRESS',priority=1}}
    local h=host(); local active=false
    h.sustain_on=function() return active end
    h.talent_known=function() return true end
    h.execute=function(a)
        if a.action=='set_sustain' then active=true; return {status='ok',instant=true} end
        return {status='ok',energy_spent=true}
    end
    local svc=service(p,h)
    Service.step(svc)
    eq(svc.controller.actions,1,'sustain and rules share run counter')
    Service.pause(svc); check(Service.resume(svc).ok,'resume permitted at settled boundary')
    eq(svc.controller.attempts,1,'resume does not refresh same-opportunity effective budget')
    eq(svc.controller.native_submissions,1,'resume does not refresh submission budget')
    h.oid=2; Service.step(svc)
    eq(svc.controller.actions,2,'new opportunity preserves run actions')
    eq(svc.controller.attempts,1,'new opportunity resets effective actions')
    local gen=svc.controller.generation; h.oid=3; Service.step(svc)
    terminal(svc,'max_consecutive_actions',gen,3,h)
    check(Service.start(svc).ok,'explicit new start establishes another run')
    eq(svc.controller.actions,0,'new start resets run actions')
end

-- POLICY-01@1.1: restarting a run resets only run accounting, never the
-- budget of the same real opportunity. This includes the manual-input path,
-- which detaches the active controller but keeps its runtime budget record.
for _,manual in ipairs{false,true} do
    local h=host(); h.outcome={status='ok',instant=true}
    local svc=service(policy{max_actions_per_tick=1},h)
    Service.step(svc)
    if manual then Service.manualInput(svc) else Service.stop(svc,'test_restart') end
    check(Service.start(svc).ok,'restart at settled same opportunity')
    eq(svc.controller.actions,0,'restart resets only run count')
    eq(svc.controller.native_submissions,1,'restart retains native submissions')
    eq(svc.controller.attempts,1,'restart retains effective actions')
    eq(svc.controller.instant_attempts,1,'restart retains instant actions')
    Service.step(svc)
    eq(#h.requests,1,'restart cannot bypass exhausted effective opportunity budget')
    h.oid=2; check(Service.resume(svc).ok,'new real opportunity refreshes budget')
    Service.step(svc)
    eq(#h.requests,2,'next real opportunity permits another action')
end
do
    local h=host(); h.outcome={status='error',energy_spent=false}
    local svc=service(policy(),h)
    for index=1,32 do
        if index>1 then Service.stop(svc,'test_restart'); check(Service.start(svc).ok,'explicit restart') end
        Service.step(svc)
    end
    eq(#h.requests,32,'32 submitted errors over same-opportunity restarts')
    Service.start(svc); Service.step(svc)
    eq(#h.requests,32,'new start cannot bypass hard native submission cap')
end
do
    local h=host(); h.outcome={status='native_pending'}
    local svc=service(policy(),h); Service.step(svc); Service.manualInput(svc)
    local restart=Service.start(svc)
    eq(restart.error.code,'not_ready','manual detach cannot forget live submitted body')
    eq(restart.error.details.cause,'native_pending','public registered code retains exact pending cause')
    settle(svc,h)
    check(Service.start(svc).ok,'start permitted after retired body truly settles')
    eq(svc.controller.attempts,1,'retired body still charged to its opportunity')
    eq(svc.controller.actions,0,'retired body never charged to new run')
end

-- Rejected-but-spent action consumes one effective slot and run cap.
do
    local h=host(); h.outcome={status='rejected',energy_spent=true}
    local svc=service(policy{max_consecutive_actions=1},h)
    local gen=svc.controller.generation; Service.step(svc)
    terminal(svc,'max_consecutive_actions',gen,1,h)
    eq(svc.controller.attempts,1,'charged rejection counts effective action')
end

-- Default hard run cap is 200 and exact, without requiring a policy override.
do
    local h=host(); local svc=service(policy(),h)
    for index=1,Schema.HARD.max_consecutive_actions do
        h.oid=index
        local gen=svc.controller.generation
        Service.step(svc)
        if index==Schema.HARD.max_consecutive_actions then
            terminal(svc,'max_consecutive_actions',gen,index,h)
        end
    end
    eq(svc.controller.actions,200,'default hard run cap consumed exactly')
end

-- Legacy limit-1 regression: a settled refusal leaves one effective slot and
-- an explicitly opted-in emergency fallback advances the world opportunity.
for _,fallback in ipairs{'release_control','evaluate_rules'} do
    local p=policy{max_actions_per_tick=1}
    p.mode.on_emergency_unavailable=fallback
    p.rules={rule('heal',true),rule('ordinary')}
    local h=host(); h.hp=30
    h.execute=function(a)
        return a.rule=='heal' and {status='rejected',energy_spent=false} or {status='ok',energy_spent=true}
    end
    local svc=service(p,h); local gen=svc.controller.generation
    local result=Service.step(svc)
    if fallback=='release_control' then
        terminal(svc,'action_denied',gen,1,h)
        eq(svc.controller.attempts,0,'refusal does not count effective')
    else
        eq(result.step.rule,'ordinary','explicit fallback selects ordinary rule')
        eq(#h.requests,2,'refusal and fallback both count submissions')
        eq(svc.controller.attempts,1,'limit one counts only effective action')
        eq(Service.status(svc).control_owner,'auto_combat','effective fallback preserves running control')
        h.oid=2; Service.step(svc)
        eq(svc.controller.actions,2,'second opportunity can progress after refusal')
    end
end

-- Known pre-submit guard denial is not settled refusal; unknown emergency
-- predicates and pending outcomes never license an ordinary fallback.
for _,why in ipairs{'guard','unknown','pending'} do
    local p=policy(); p.mode.on_emergency_unavailable='evaluate_rules'
    p.rules={rule('heal',true),rule('ordinary')}
    local h=host(); h.hp=30
    if why=='guard' then h.guard=function() return {action='reject',reason='unknown_geometry'} end
    elseif why=='unknown' then
        p.rules[1].when={cooldown_ready={talent='T_HEALING_LIGHT'}}
        p.rules[3]=rule('rejected_emergency',true); p.rules[3].priority=101
        h.execute=function() return {status='rejected',energy_spent=false} end
    else h.outcome={status='native_pending'} end
    local svc=service(p,h); Service.step(svc)
    for _,a in ipairs(h.requests) do check(a.rule~='ordinary','no fallback after '..why) end
    if why=='guard' then eq(#h.requests,0,'guard refusals do not count submissions') end
    if why=='unknown' then eq(svc.controller.reason,'unknown_safety','unknown blocks widening') end
    if why=='pending' then
        for _=1,5 do Service.step(svc) end
        eq(#h.requests,1,'pending frames never resubmit')
        eq(svc.controller.actions,0,'pending success not guessed from ready phase')
    end
end

-- Native submission hard cap persists across display pumps and user resumes.
-- The host returns explicit errors; resuming is a caller choice, not automatic
-- retry. The 32nd request may itself be pending and must be tracked to settlement.
for _,pendingLast in ipairs{false,true} do
    local h=host(); h.outcome={status='error',energy_spent=false}
    local svc=service(policy(),h)
    for index=1,32 do
        if index>1 then check(Service.resume(svc).ok,'resume error boundary without resetting counters') end
        if index==32 and pendingLast then h.outcome={status='native_pending'} end
        local gen=svc.controller.generation
        Service.step(svc)
        eq(#h.requests,index,'one request per resumed pump')
        eq(svc.controller.native_submissions,index,'cross-pump submission count')
        if index==32 then
            if pendingLast then
                eq(svc.controller.state,'waiting_native','32nd pending remains tracked')
                Service.step(svc); eq(#h.requests,32,'pending cap never resubmits')
                settle(svc,h,{status='rejected',energy_spent=false})
            end
            terminal(svc,'native_submission_limit',gen,32,h)
        end
    end
end

-- A pending result counts exactly once, belongs to the original run and is not
-- lost when a pause changes the scheduling generation.
do
    local h=host(); h.outcome={status='native_pending',energy_spent=true}
    local svc=service(policy{max_consecutive_actions=1},h)
    Service.step(svc)
    eq(svc.controller.native_submissions,1,'pending first submission counts once')
    eq(svc.controller.actions,0,'pending energy observation waits for final accounting')
    Service.pause(svc,'test_pause')
    check(Service.resume(svc).ok,'resume scheduling while native body remains pending')
    eq(svc.controller.state,'waiting_native','resume remains at pending boundary')
    Service.step(svc); eq(#h.requests,1,'pending resume never resubmits')
    local gen=svc.controller.generation
    local step,outcome=settle(svc,h,{instant=true})
    terminal(svc,'max_consecutive_actions',gen,1,h)
    eq(svc.controller.actions,1,'same-run paused body settles once')
    eq(svc.controller.instant_attempts,1,'settled instant is counted')
    check(Service.nativeSettled(svc,outcome)==nil,'duplicate final settlement is ignored')
    eq(svc.controller.actions,1,'duplicate does not double count')
    h.outcome={status='native_pending'}; h.oid=2
    check(Service.start(svc).ok,'new run after settled stop')
    Service.step(svc)
    check(Service.nativeSettled(svc,outcome)==nil,'old-run outcome cannot settle new pending body')
    eq(svc.controller.actions,0,'old run cannot charge new run')
    settle(svc,h)
    eq(svc.controller.actions,1,'new run body independently settles')
end

-- NATIVE-PENDING-01: after settlement releases the lease, another scheduler or
-- explicit step must not reinterpret the terminal run as a control-loss event.
-- The native outcome is a unit double; the source/dist probe covers the engine.
for _,pending in ipairs{false,true} do
    local h=host()
    if pending then h.outcome={status='native_pending',energy_spent=true} end
    local p=policy{max_consecutive_actions=1}
    p.rules={rule('rest',false,{action='rest',max_turns=2})}
    local svc=service(p,h)
    local controller=svc.controller
    local generation=controller.generation
    Service.step(svc)
    if pending then settle(svc,h) end
    terminal(svc,'max_consecutive_actions',generation,1,h)
    local status=Json.encode(Service.status(svc))
    local log=Json.encode(Service.log(svc,32))
    for _=1,3 do
        local stepped=Service.step(svc)
        eq(svc.controller,controller,'a terminal step retains the same settled controller')
        check(not stepped.ok and stepped.error.code=='not_running','terminal step reports not_running')
        eq(Json.encode(Service.status(svc)),status,'terminal step preserves reason, counters, generation and lease')
        eq(Json.encode(Service.log(svc,32)),log,'terminal step emits no control_lost or duplicate stop')
        eq(#h.requests,1,'terminal step never resubmits native work')
    end
end

-- Settlement while paused without hitting a cap permits resume and retains the
-- same opportunity budget; new ready identity alone resets that budget.
do
    local h=host(); h.outcome={status='native_pending'}
    local svc=service(policy{max_actions_per_tick=2,max_consecutive_actions=2},h)
    Service.step(svc); Service.pause(svc)
    settle(svc,h)
    eq(svc.controller.state,'paused','settlement does not override user pause')
    check(Service.resume(svc).ok,'resume after real settlement')
    eq(svc.controller.actions,1,'resume retains run accounting')
    eq(svc.controller.attempts,1,'resume retains opportunity accounting')
    h.outcome={status='ok'}; local gen=svc.controller.generation
    Service.step(svc); terminal(svc,'max_consecutive_actions',gen,2,h)
end

-- A cap and a native integrity deviation share one terminal generation change;
-- the more precise deviation remains the reason. Exercise sync and async paths.
for _,async in ipairs{false,true} do
    for _,kind in ipairs{'postcondition_mismatch','sequence_deviation'} do
        local h=host(); local detail={reason=kind=='postcondition_mismatch'
            and 'movement_postcondition_mismatch' or 'unexpected_target_request'}
        h.outcome=async and {status='native_pending'} or {status='ok',energy_spent=true,[kind]=detail}
        local svc=service(policy{max_consecutive_actions=1},h); local gen=svc.controller.generation
        Service.step(svc)
        if async then
            settle(svc,h,{[kind]=detail})
            eq(svc.controller.generation,gen,'counting alone does not preempt deviation with cap')
            if kind=='postcondition_mismatch' then Service.nativePostconditionMismatch(svc,detail)
            else Service.nativeDeviation(svc,detail) end
        end
        terminal(svc,detail.reason,gen,1,h)
        eq(svc.controller.actions,1,'effective mismatch counted once')
    end
end

-- Dry-run calls no executor and changes none of the live counters or lease.
do
    local h=host(); local svc=service(policy{max_actions_per_tick=2},h)
    Service.step(svc)
    local before=Json.encode(Service.status(svc).run)
    for _=1,3 do check(Service.dryRun(svc,{}).ok,'dry run succeeds') end
    eq(Json.encode(Service.status(svc).run),before,'dry run leaves every counter unchanged')
    eq(#h.requests,1,'dry run makes no native submissions')
    local log=Service.log(svc,1).events[1]
    eq(log.native_submissions,1,'log distinguishes submissions')
    eq(log.effective_actions,1,'log distinguishes effective actions')
    eq(log.run_actions,1,'log distinguishes run actions')
    eq(log.instant_actions,0,'log distinguishes instant actions')
end

-- Legacy emergency policy migration: validate/import warn, original envelope
-- hash verifies before migration, restored approval cannot silently activate.
do
    local old=policy(); old.mode.on_emergency_unavailable=nil
    local original=Json.encode(old); local oldHash=Schema.hash(old)
    local valid,_,warnings=Schema.validate(old)
    check(valid and warnings[1].code=='emergency_fallback_migration','schema surfaces migration warning')
    local svc=Service.new()
    check(Service.validate(svc,old).warnings[1]~=nil,'validate surfaces warning')
    eq(Json.encode(old),original,'validate never mutates user policy')
    local envelope=Json.encode{format=1,envelope='tome-auto-combat-policy',hash=oldHash,policy=old}
    local imported=Service.import(svc,envelope)
    check(imported.ok and imported.warnings[1]~=nil,'legacy import surfaces migration warning')
    eq(imported.original_hash,oldHash,'import verifies original hash before normalisation')
    eq(imported.policy.mode.on_emergency_unavailable,'release_control','normalised import explicit default')
    check(imported.hash~=oldHash,'migration changes approval hash visibly')
    local tampered=Json.decode(envelope); tampered.policy.name='changed'
    eq(Service.import(svc,Json.encode(tampered)).error.code,'hash_mismatch','migration cannot hide tampered old envelope')
    local draft=policy(); draft.id='unsaved-other-draft'
    check(Service.loadState(svc,{format=2,draft=draft,approved=old}),'legacy character loads')
    local got=Service.get(svc)
    check(got.approved==nil and got.running==nil,'old approval/running not retained')
    eq(got.draft.mode.on_emergency_unavailable,'release_control','legacy approved becomes explicit draft')
    eq(got.migration.previous_draft.id,draft.id,'existing distinct draft preserved')
    eq(Json.encode(got.migration.original_approved),original,'original user approval data preserved')
    eq(Service.activate(svc).error.code,'not_approved','migrated policy requires new approval')
    local saved=Service.saveState(svc)
    eq(saved.format,3,'migration archive has explicit save format')
    check(saved.run_id==nil and saved.controller==nil and saved.arbiter==nil,'runtime tokens never saved')
    local reloaded=Service.new(); Service.loadState(reloaded,saved)
    check(Service.get(reloaded).migration.requires_reapproval,'migration notice survives reload')
    check(Service.approve(reloaded).ok and Service.activate(reloaded).ok,'explicit approve then activate succeeds')
    check(not Service.get(reloaded).migration.requires_reapproval,'approval resolves migration requirement')
    local untouched=policy(); untouched.mode={on_low_hp='evaluate_rules'}
    local other=Service.new(); Service.loadState(other,{approved=untouched})
    check(Service.get(other).approved~=nil and Service.get(other).migration==nil,
        'unaffected scheduling mode retains approval without pointless migration')
    local noThreshold=policy(); noThreshold.mode=nil; noThreshold.safety={}
    check(#select(3,Schema.validate(noThreshold))==0,'unreachable emergency mode needs no migration')
end
print('Auto-combat system fixes: '..checks..' checks passed')
