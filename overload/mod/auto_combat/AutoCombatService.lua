-- GPL-3.0-or-later. Auto-combat service: the MCP-facing orchestration of the
-- policy store, the control arbiter, the capability catalogue, the log and the
-- controller. Engine-agnostic: the live host (audited reads + action execution)
-- is injected through `options.host_factory`, so the whole surface is unit
-- testable without the game.
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local Store=require 'mod.auto_combat.PolicyStore'
local Arbiter=require 'mod.auto_combat.ControlArbiter'
local Log=require 'mod.auto_combat.PolicyLog'
local Combat=require 'mod.auto_combat.AutoCombat'
local Evaluator=require 'mod.auto_combat.PolicyEvaluator'
local Json=require 'mod.mcp_bridge.Json'
local Presets=require 'mod.auto_combat.PolicyPresets'
local PolicyIO=require 'mod.auto_combat.PolicyIO'
local AssistantAdapter=require 'mod.auto_combat.AssistantAdapter'
local M={}
M.SOURCE='auto_combat'
-- Option A (round-3 follow-up): the two safety pauses hand control back to the
-- player immediately. The run stops and the lease returns to `manual`, so a
-- remote action needs no reconnect and `resume` cannot loop-pause.
M.SAFETY_PAUSES={flee_below_hp_pct=true,no_emergency_action=true}

function M.new(options)
    options=options or {}
    return {store=Store.new(),arbiter=Arbiter.new(),log=Log.new(options.log_limit or 256),
        strict=options.strict~=false,controller=nil,host_factory=options.host_factory,
        dry_run_host_factory=options.dry_run_host_factory,log_context=options.log_context,
        revision=0}
end

local function fail(code,details)
    return {ok=false,error={code=code,details=details}}
end
local function ok(payload)
    payload=payload or {}
    payload.ok=true
    return payload
end

-- Optional replay metadata (world tick / revision / level) injected by the
-- runtime; the service stays engine-agnostic and simply tags log entries.
local function logContext(svc)
    if type(svc.log_context)=='function' then
        local ok,ctx=pcall(svc.log_context)
        if ok and type(ctx)=='table' then return ctx end
    end
    return {}
end

local function withContext(svc,event)
    local ctx=logContext(svc)
    if ctx.tick~=nil then event.tick=ctx.tick end
    if ctx.revision~=nil then event.revision=ctx.revision end
    if ctx.level_instance_id~=nil then event.level_instance_id=ctx.level_instance_id end
    return event
end

function M.status(svc)
    local status=Store.status(svc.store)
    local control=Arbiter.status(svc.arbiter)
    status.control_owner=control.owner
    status.actionable=control.actionable
    status.source=M.SOURCE
    status.strict=svc.strict
    if svc.controller then
        status.run=svc.controller:status()
        status.last_decisions=svc.controller:recentDecisions(5)
    end
    status.log=Log.status(svc.log)
    return ok(status)
end

-- INT-06/D10: `get` returns the three actual versions (not only hashes);
-- `clear` empties the draft only and never the approved/running versions.
function M.get(svc)
    return ok({draft=svc.store.draft,approved=svc.store.approved,running=svc.store.running,
        active=svc.store.active,revision=svc.store.revision,hashes=Store.hashes(svc.store),
        draft_hash=Store.hashes(svc.store).draft,approved_hash=Store.hashes(svc.store).approved,
        running_hash=Store.hashes(svc.store).running})
end

function M.clear(svc)
    svc.store.draft=nil
    svc.store.revision=svc.store.revision+1
    svc.revision=svc.revision+1
    local hashes=Store.hashes(svc.store)
    return ok({cleared='draft',draft_hash=hashes.draft,approved_hash=hashes.approved,running_hash=hashes.running})
end

function M.validate(svc,policy)
    local schema_ok,errors=Schema.validate(policy)
    if not schema_ok then return fail('invalid_policy',{errors=errors}) end
    local compatible,semantic=Catalog.verify(policy)
    if not compatible then return fail('invalid_policy',{errors=semantic}) end
    return ok({valid=true,hash=Schema.hash(policy)})
end

local function findRule(policy,id)
    for _,rule in ipairs(policy.rules or {}) do if rule.id==id then return rule end end
    return nil
end

-- Planning-level validation (design §7): evaluate a policy against the current
-- audited read snapshot and report what it *would* choose. This is a pure read:
-- it never calls the executor, spends energy, invokes a talent or opens a dialog,
-- and it works with live execution disabled because it only needs reads.
--
-- Policy resolution: an explicit `args.policy` wins; otherwise running, then
-- approved, then draft. It is validated exactly like any other policy.
function M.dryRun(svc,args)
    args=args or {}
    local policy=args.policy
    local source
    if policy~=nil then
        source='request'
    else
        policy,source=svc.store.running,'running'
        if policy==nil then policy,source=svc.store.approved,'approved' end
        if policy==nil then policy,source=svc.store.draft,'draft' end
    end
    if policy==nil then return fail('no_policy',{details='no draft, approved or running policy'}) end
    local checked=M.validate(svc,policy)
    if not checked.ok then return checked end
    -- Prefer the read-only host; the live executor host is a safe fallback
    -- because dry run never calls request()/execute(). Either way this ignores
    -- `allow_auto_combat_execution`: dry run only needs audited reads.
    local factory=svc.dry_run_host_factory or svc.host_factory
    if not factory then return fail('snapshot_unavailable',{details='no audited read host'}) end
    local host=factory(svc,policy)
    if not host or type(host.snapshot)~='function' then return fail('snapshot_unavailable') end
    local policy_hash=Schema.hash(policy)
    local default_selector=policy.targeting and policy.targeting.default
    local function snapshotFor(selector)
        local rc=host.snapshot(selector) or {}
        rc.attempts=0
        rc.denied={}
        return rc
    end
    local ctx=snapshotFor(default_selector)
    -- MFT-REV-05: mirror the controller's bounded deny/fall-through loop so the
    -- reported action is the one live execution would next submit. This never
    -- calls request()/execute() or commits anything.
    local maxActions=(policy.limits and policy.limits.max_actions_per_tick) or 1
    local maxInstant=(policy.limits and policy.limits.max_instant_per_tick) or 3
    local denied={}
    local attempts=0
    -- MFT-REV-05(a): the instant cap is a distinct per-opportunity counter that
    -- advances only after a successful instant action, not the total attempt
    -- counter. A rejected candidate never consumes an instant slot.
    local instant_attempts=0
    local trace={}
    local decision={decision='hold',reason='no_rule_matched',results={}}
    local bound_target,target_distance,binding,movement,risk_detail
    local loop_paused=false
    local rebound_flag=false
    local bound_selector
    for _=1,8 do
        local base=snapshotFor(default_selector)
        base.attempts=attempts
        base.denied=denied
        local d=Evaluator.evaluate(policy,base,{context_for=function(selector)
            if selector==default_selector then return base end
            local rc=snapshotFor(selector)
            rc.attempts=attempts
            rc.denied=denied
            return rc
        end})
        decision=d
        if d.decision~='act' then break end
        -- The instant cap is a controller rule; mirror its counter semantics
        -- (instant_attempts, not attempts) without executing.
        if (d.action=='use_talent' or d.action=='set_sustain') and instant_attempts>=maxInstant then
            decision={decision='pause',reason='instant_budget_exhausted',rule=d.rule,
                results=d.results,layer=d.layer}
            loop_paused=true
            break
        end
        -- Same-target binding check the controller performs.
        local bt,td=base.bound_target,base.enemy_distance
        rebound_flag=false
        bound_selector=nil
        local ok=true
        local current=base.binding_selector
        if current==nil then current=default_selector end
        if d.target~=nil and d.target~=current then
            local rebound=host.snapshot(d.target)
            local rule=findRule(policy,d.rule)
            if rebound and rebound.binding_selector==d.target
                and rule and Evaluator.evalCondition(rule.when,rebound)==Evaluator.TRUE then
                bt,td=rebound.bound_target,rebound.enemy_distance
                rebound_flag=true
                bound_selector=d.target
            else
                ok=false
            end
        end
        if not ok then
            denied[d.rule]=true
            trace[#trace+1]={rule=d.rule,reason='target_rebind_failed'}
        else
            local plan
            local plan_fail,plan_fail_err
            if d.action=='move' or d.destination~=nil or d.target_plan~=nil then
                if type(host.plan)=='function' then
                    local planned,planned_err=host.plan({action=d.action,talent=d.talent,
                        destination=d.destination,target_plan=d.target_plan,direction=d.direction,
                        target=d.target,bound_target=bt})
                    if planned and planned.plan then plan=planned.plan
                    else plan_fail=(planned and planned.reason)
                        or (planned_err and planned_err.reason) or 'destination_unavailable'
                        plan_fail_err=(planned_err and planned_err.annotation) or (planned and planned.annotation)
                    end
                else
                    plan_fail='movement_provider_unavailable'
                end
            end
            if plan_fail then
                if plan_fail=='unsupported_target_plan' then
                    -- Live control pauses on a multi-prompt plan; dry-run must
                    -- classify it the same way (MFT-REV-05(b)).
                    decision={decision='pause',reason=plan_fail,rule=d.rule,
                        results=d.results,layer=d.layer}
                    loop_paused=true
                    break
                end
                denied[d.rule]=true
                trace[#trace+1]={rule=d.rule,reason=plan_fail,annotation=plan_fail_err}
            else
                local guard=host.guard and host.guard({rule=d.rule,action=d.action,talent=d.talent,
                    target=d.target,bound_target=bt,emergency=d.emergency==true})
                if guard and guard.action=='pause' then
                    decision={decision='pause',reason=guard.reason,rule=d.rule,results=d.results,layer=d.layer}
                    risk_detail=guard.detail
                    loop_paused=true
                    break
                end
                if guard and guard.action=='reject' then
                    attempts=attempts+1
                    denied[d.rule]=true
                    trace[#trace+1]={rule=d.rule,reason=guard.reason,risk=guard.detail}
                else
                    -- This is the action live execution would next submit.
                    decision=d
                    bound_target,target_distance=bt,td
                    -- Keep the default binding selector unless a non-default
                    -- selector was re-bound and re-checked above.
                    binding={ok=true,selector=bound_selector or base.binding_selector,
                        rebound=rebound_flag or nil}
                    risk_detail=guard and guard.detail
                    if plan then movement={plan=plan.kind,annotation=plan.annotation} end
                    break
                end
            end
        end
        if attempts>=maxActions then
            decision={decision='pause',reason='budget_exhausted',rule=decision.rule,
                results=decision.results,layer=decision.layer}
            loop_paused=true
            break
        end
    end
    -- A planner/guard fall-through selection keeps the same binding metadata.
    if decision.decision=='act' and binding==nil then
        binding={ok=true,selector=decision.target}
    end
    local snapshot=type(host.snapshot_meta)=='function' and host.snapshot_meta() or nil
    return ok({dry_run=true,executed=false,side_effects='none',
        policy_hash=policy_hash,schema=Schema.SCHEMA,policy_source=source,
        snapshot=snapshot,
        decision=decision.decision,layer=decision.layer,critical=decision.critical==true,
        reason=decision.reason,
        rule=decision.rule,action=decision.action,talent=decision.talent,
        max_turns=decision.max_turns,
        target=decision.target,bound_target=bound_target,target_distance=target_distance,
        binding=binding,movement=movement,risk=risk_detail,
        rejected=trace,paused=loop_paused or nil,
        results=decision.results or {},unsupported=Json.array()})
end

function M.setDraft(svc,policy,expected_hash)
    local checked=M.validate(svc,policy)
    if not checked.ok then return checked end
    local stored,err=Store.setDraft(svc.store,policy,expected_hash)
    if not stored then return fail(err.code,err) end
    svc.revision=svc.revision+1
    return ok(stored)
end

function M.approve(svc,expected_hash)
    local approved,err=Store.approve(svc.store,expected_hash)
    if not approved then return fail(err.code,err) end
    svc.revision=svc.revision+1
    return ok(approved)
end

-- Activation promotes the approved policy to running and requests the lease.
-- Certification alone never grants control. AC-08: a changed approved hash
-- invalidates the old controller generation so the reported running hash is
-- never ahead of the executor.
function M.activate(svc,expected_hash)
    if not svc.store.approved then return fail('not_approved') end
    local previous_running=svc.store.running and Schema.hash(svc.store.running) or nil
    local granted,reason=Arbiter.grant(svc.arbiter,M.SOURCE,'auto-combat activated')
    if not granted then return fail(reason,{control_owner=svc.arbiter.owner}) end
    local activated,err=Store.activate(svc.store,expected_hash)
    if not activated then
        Arbiter.revoke(svc.arbiter,M.SOURCE,'activation failed')
        return fail(err.code,err)
    end
    local now_running=Schema.hash(svc.store.running)
    if svc.controller and svc.controller.state~='stopped' and previous_running~=nil
        and previous_running~=now_running then
        svc.controller:stop('policy_replaced')
        svc.controller=nil
    end
    svc.revision=svc.revision+1
    return ok(activated)
end

function M.deactivate(svc)
    if svc.controller then svc.controller:stop('deactivated') end
    svc.controller=nil
    Store.deactivate(svc.store)
    if svc.arbiter.owner==M.SOURCE then Arbiter.revoke(svc.arbiter,M.SOURCE,'deactivated') end
    svc.revision=svc.revision+1
    return ok({active=false})
end

function M.start(svc)
    if not svc.store.running then return fail('not_activated') end
    if not svc.host_factory then return fail('execution_not_available') end
    if svc.controller and svc.controller.state~='stopped' then
        return fail('already_running',{state=svc.controller.state})
    end
    -- AC-09: `start` re-acquires the lease for an already-active policy when the
    -- owner is manual, so stop / no-visible-enemies / manual input can restart
    -- without a deactivate detour. Another owner still owns the lease.
    if not Arbiter.canAct(svc.arbiter,M.SOURCE) then
        local granted,reason=Arbiter.grant(svc.arbiter,M.SOURCE,'auto-combat start')
        if not granted then
            return fail('control_not_held',{control_owner=svc.arbiter.owner,reason=reason})
        end
    end
    local host=svc.host_factory(svc)
    if not host then return fail('execution_not_available') end
    svc.controller=Combat.new(svc.store.running,host,{strict=svc.strict,notify=function(event)
        Log.add(svc.log,withContext(svc,{kind=event.kind,reason=event.reason,rule=event.rule,talent=event.talent,
            target=event.target,action=event.action,elapsed_ticks=event.elapsed_ticks,
            elapsed_frames=event.elapsed_frames,generation=event.generation,
            -- P2-1: a deterministic-landing retry carries the underlying native
            -- result (for example `blocked`) so the refusal stays auditable.
            native_result=event.code,
            policy_hash=Schema.hash(svc.store.running)}))
    end})
    local started=svc.controller:start()
    return ok({run=started,state=svc.controller.state,generation=svc.controller.generation})
end

function M.stop(svc,reason)
    reason=reason or 'stopped'
    local previous=svc.controller and svc.controller.state or nil
    local generation=svc.controller and svc.controller.generation or nil
    if svc.controller then svc.controller:stop(reason) end
    if svc.arbiter.owner==M.SOURCE then Arbiter.revoke(svc.arbiter,M.SOURCE,reason) end
    -- An explicit stop of a running/paused run is a real transition: record the
    -- run boundary. A stop of an already-stopped run stays silent (dedupe).
    if previous and previous~='stopped' then
        Log.add(svc.log,withContext(svc,{kind='stopped',reason=reason,generation=generation,
            policy_hash=svc.store.running and Schema.hash(svc.store.running) or nil}))
    end
    return ok({state='stopped'})
end

function M.pause(svc,reason)
    if not svc.controller then return fail('not_running') end
    if svc.controller.state=='stopped' then return fail('not_running') end
    return ok(svc.controller:pause(reason or 'paused'))
end

function M.resume(svc)
    if not svc.controller then return fail('not_running') end
    if svc.controller.state=='stopped' then
        return fail('not_running',{details='the run is stopped; use start to re-acquire the lease'})
    end
    if not Arbiter.canAct(svc.arbiter,M.SOURCE) then
        return fail('control_not_held',{control_owner=svc.arbiter.owner})
    end
    local resumed=svc.controller:resume()
    if resumed and resumed.ok==false then
        return fail(resumed.code or 'not_paused',{state=resumed.state})
    end
    return ok(resumed)
end

-- Called on a manual input so the plugin loses control immediately.
function M.manualInput(svc,reason)
    local moved=Arbiter.manualInput(svc.arbiter,reason or 'manual_input')
    if svc.controller and svc.controller.state~='stopped' then
        svc.controller:stop('manual_input')
    end
    svc.controller=nil
    return moved
end

-- P0/F4: the executor had to abort an auto-slot native invocation that did not
-- settle within its bound (for example a native target request the executor
-- cannot answer). Record the typed event on the controller (bounded decision
-- ring + policy log) and hand control back to the player. The native side of the
-- abort (cancel the UI, release the invocation) is owned by the Runtime pump;
-- this function only arbitrates control and records the event so the stall is
-- never invisible in the policy log.
function M.nativeAbort(svc,info)
    if not svc then return nil end
    info=info or {}
    local code=info.code or 'native_timeout'
    local entry
    if svc.controller then entry=svc.controller:nativeAborted(info) end
    -- Keep the stopped run visible for status/observe (like the Option-A safety
    -- handoff) and release the lease so the player can act immediately.
    if svc.controller and svc.controller.state~='stopped' then svc.controller:stop(code) end
    if svc.arbiter.owner==M.SOURCE then Arbiter.revoke(svc.arbiter,M.SOURCE,code) end
    return entry
end

local function resourcesOf(host)
    if host and type(host.resources)=='function' then
        local ok,value=pcall(host.resources)
        if ok and type(value)=='table' then return value end
    end
    return nil
end

-- Advance the controller one action opportunity (the live pump calls this).
function M.step(svc)
    if not svc.controller then return fail('not_running') end
    if not Arbiter.canAct(svc.arbiter,M.SOURCE) then
        svc.controller:stop('control_lost')
        svc.controller=nil
        return fail('control_lost')
    end
    local host=svc.controller.host
    local before=resourcesOf(host)
    local step=svc.controller:onOpportunity()
    local after=resourcesOf(host)
    local policy_hash=Schema.hash(svc.store.running)
    -- Option A: a safety pause hands control straight back to the player. Stop
    -- the run and release the lease so a remote act needs no reconnect and
    -- `resume` refuses. The pause transition was already logged once by the
    -- controller notify callback during onOpportunity (no second event here).
    if step.action=='paused' and M.SAFETY_PAUSES[step.reason] then
        if svc.arbiter.owner==M.SOURCE then Arbiter.revoke(svc.arbiter,M.SOURCE,step.reason) end
        svc.controller:stop(step.reason)
        return ok({step=step,state=svc.controller.state,generation=svc.controller.generation,handoff=true})
    end
    -- Pauses and denials are already logged by the controller notify callback,
    -- so only the successful/terminal steps are added here (no duplicates).
    if step.action=='acted' then
        Log.add(svc.log,withContext(svc,{kind=step.action,reason=step.reason,rule=step.rule,talent=step.talent,
            target=step.bound_target,generation=step.generation,
            movement=step.destination,risk=step.risk,
            native_result=step.outcome and step.outcome.status or nil,
            rule_results=step.results,rejections=step.rejections,
            resources_before=before,resources_after=after,policy_hash=policy_hash}))
    elseif step.action=='stopped' then
        -- The controller ended itself (no visible enemy): return control.
        Log.add(svc.log,withContext(svc,{kind='stopped',reason=step.reason,generation=step.generation,
            rule_results=step.results,rejections=step.rejections,
            resources_before=before,resources_after=after,policy_hash=policy_hash}))
        if svc.arbiter.owner==M.SOURCE then Arbiter.revoke(svc.arbiter,M.SOURCE,step.reason or 'stopped') end
    end
    return ok({step=step,state=svc.controller.state,generation=svc.controller.generation})
end

function M.log(svc,limit)
    return ok({events=Log.tail(svc.log,limit or 32),status=Log.status(svc.log)})
end
-- Replay/export the §10 decision trace: an ascending, cursor-paged slice plus a
-- header describing the run's policy/state context. This is a decision trace,
-- not a deterministic re-execution: raw inputs and adapter versions are not
-- stored, and the log is deliberately in-memory runtime state (never saved).
function M.replay(svc,args)
    args=args or {}
    local after=args.after_seq or 0
    local limit=args.limit or 64
    if type(after)~='number' or after<0 or after~=after then
        return fail('invalid_argument',{details='after_seq'})
    end
    if type(limit)~='number' or limit<1 or limit>256 or limit~=limit then
        return fail('invalid_argument',{details='limit'})
    end
    local entries=Log.slice(svc.log,after,limit)
    local header={
        schema=Schema.SCHEMA,
        policy_hash=svc.store.running and Schema.hash(svc.store.running) or nil,
        session_revision=svc.revision,
        control_owner=svc.arbiter.owner,
        run_state=svc.controller and svc.controller.state or 'stopped',
        generation=svc.controller and svc.controller.generation or nil,
        log_limit=svc.log.limit,
    }
    local next_seq=after
    if entries[#entries] then next_seq=entries[#entries].seq end
    return ok({replay=true,executed=false,side_effects='none',header=header,
        entries=entries,next_seq=next_seq,status=Log.status(svc.log)})
end

-- Built-in presets and import/export -----------------------------------------
function M.presets(svc)
    return ok({names=Presets.names(),presets=Presets.summaries()})
end

function M.preset(svc,name)
    local policy=Presets.copy(name)
    if not policy then return fail('unknown_preset',{name=name}) end
    return ok({policy=policy,hash=Schema.hash(policy)})
end

function M.export(svc)
    local source=svc.store.draft or svc.store.approved
    if not source then return fail('no_policy') end
    local document,err=PolicyIO.export(source)
    if not document then return fail(err.code,err) end
    return ok({document=document,hash=Schema.hash(source)})
end

function M.import(svc,document)
    local policy,info=PolicyIO.import(document)
    if not policy then return fail(info.code,info) end
    return ok({policy=policy,hash=info.hash})
end

-- Generation-only import of a pinned legacy-assistant export. Produces a policy
-- draft (+ warnings/unsupported) and, only when `args.store==true`, stores it as
-- the draft. It never approves, activates or starts a run.
function M.importAssistant(svc,args)
    args=args or {}
    local config=args.config
    if config==nil then
        if type(args.document)~='string' then
            return fail('invalid_argument',{details='config or document is required'})
        end
        local decoded_ok,decoded=pcall(Json.decode,args.document)
        if not decoded_ok or type(decoded)~='table' then
            return fail('invalid_document',{details='document is not valid JSON'})
        end
        config=decoded
    end
    if type(config)~='table' then return fail('invalid_argument',{details='config must be an object'}) end
    local result=AssistantAdapter.translate(config)
    if not result.ok then return fail(result.error.code,result.error) end
    local stored=nil
    if args.store==true then
        local saved,err=Store.setDraft(svc.store,result.draft,args.expected_hash)
        if not saved then return fail(err.code,err) end
        svc.revision=svc.revision+1
        stored=saved
    end
    return ok({imported=true,draft=result.draft,hash=result.hash,warnings=result.warnings,
        unsupported=result.unsupported,version=result.version,stored=stored})
end

-- Character persistence: draft/approved follow the character, running state and
-- control do not (reading a character never resumes automatic action).
function M.saveState(svc)
    return {format=1,draft=svc.store.draft,approved=svc.store.approved}
end

function M.loadState(svc,data)
    if type(data)~='table' then return false end
    local function valid(policy)
        if type(policy)~='table' then return false end
        return Schema.validate(policy)==true and Catalog.verify(policy)==true
    end
    if valid(data.draft) then svc.store.draft=data.draft end
    if valid(data.approved) then svc.store.approved=data.approved end
    svc.store.running=nil; svc.store.active=false
    svc.controller=nil
    return true
end

-- Dispatch a tome.policy op. `args` is the request's policy object.
function M.handle(svc,op,args)
    args=args or {}
    if op=='status' then return M.status(svc) end
    if op=='get' then return M.get(svc) end
    if op=='clear' then return M.clear(svc) end
    if op=='validate' then return M.validate(svc,args.policy) end
    if op=='dry_run' then return M.dryRun(svc,args) end
    if op=='set_draft' then return M.setDraft(svc,args.policy,args.expected_hash) end
    if op=='approve' then return M.approve(svc,args.expected_hash) end
    if op=='activate' then return M.activate(svc,args.expected_hash) end
    if op=='deactivate' then return M.deactivate(svc) end
    if op=='start' then return M.start(svc) end
    if op=='stop' then return M.stop(svc,args.reason) end
    if op=='pause' then return M.pause(svc,args.reason) end
    if op=='resume' then return M.resume(svc) end
    if op=='log' then return M.log(svc,args.limit) end
    if op=='replay' then return M.replay(svc,args) end
    if op=='presets' then return M.presets(svc) end
    if op=='preset' then return M.preset(svc,args.name) end
    if op=='export' then return M.export(svc) end
    if op=='import' then return M.import(svc,args.document) end
    if op=='import_assistant' then return M.importAssistant(svc,args) end
    return fail('invalid_argument',{details='unknown policy op'})
end
return M
