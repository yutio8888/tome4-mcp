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
    local ctx=host.snapshot(default_selector) or {}
    ctx.attempts=0
    ctx.denied={}
    local decision=Evaluator.evaluate(policy,ctx,{context_for=function(selector)
        if selector==default_selector then return ctx end
        local rc=host.snapshot(selector) or {}
        rc.attempts=0
        rc.denied={}
        return rc
    end})
    -- A rule's condition and the target it acts on must bind the same object, so
    -- mirror the controller: if the winning rule selects a different target than
    -- the context, re-bind and re-check before reporting it.
    local bound_target=ctx.bound_target
    local target_distance=ctx.enemy_distance
    local binding={ok=true,selector=ctx.binding_selector}
    if decision.decision=='act' and decision.target~=nil and ctx.binding_selector~=nil
        and decision.target~=ctx.binding_selector then
        local rebound=host.snapshot(decision.target)
        local rule=findRule(policy,decision.rule)
        if rebound and rebound.binding_selector==decision.target
            and rule and Evaluator.evalCondition(rule.when,rebound)==Evaluator.TRUE then
            bound_target=rebound.bound_target
            target_distance=rebound.enemy_distance
            binding={ok=true,selector=decision.target,rebound=true}
        else
            bound_target=nil;target_distance=nil
            binding={ok=false,selector=decision.target,reason='target_rebind_failed'}
        end
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
        binding=binding,results=decision.results or {},unsupported=Json.array()})
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
            target=event.target,generation=event.generation,
            policy_hash=Schema.hash(svc.store.running)}))
    end})
    local started=svc.controller:start()
    return ok({run=started,state=svc.controller.state,generation=svc.controller.generation})
end

function M.stop(svc,reason)
    if svc.controller then svc.controller:stop(reason or 'stopped') end
    if svc.arbiter.owner==M.SOURCE then Arbiter.revoke(svc.arbiter,M.SOURCE,reason or 'stopped') end
    return ok({state='stopped'})
end

function M.pause(svc,reason)
    if not svc.controller then return fail('not_running') end
    return ok(svc.controller:pause(reason or 'paused'))
end

function M.resume(svc)
    if not svc.controller then return fail('not_running') end
    if not Arbiter.canAct(svc.arbiter,M.SOURCE) then
        return fail('control_not_held',{control_owner=svc.arbiter.owner})
    end
    return ok(svc.controller:resume())
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
    -- Pauses and denials are already logged by the controller notify callback,
    -- so only the successful/terminal steps are added here (no duplicates).
    if step.action=='acted' then
        Log.add(svc.log,withContext(svc,{kind=step.action,reason=step.reason,rule=step.rule,talent=step.talent,
            target=step.bound_target,generation=step.generation,
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
