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
local Presets=require 'mod.auto_combat.PolicyPresets'
local PolicyIO=require 'mod.auto_combat.PolicyIO'
local M={}
M.SOURCE='auto_combat'

function M.new(options)
    options=options or {}
    return {store=Store.new(),arbiter=Arbiter.new(),log=Log.new(options.log_limit or 256),
        strict=options.strict~=false,controller=nil,host_factory=options.host_factory,
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

function M.status(svc)
    local status=Store.status(svc.store)
    local control=Arbiter.status(svc.arbiter)
    status.control_owner=control.owner
    status.actionable=control.actionable
    status.source=M.SOURCE
    status.strict=svc.strict
    if svc.controller then status.run=svc.controller:status() end
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
-- Certification alone never grants control.
function M.activate(svc,expected_hash)
    if not svc.store.approved then return fail('not_approved') end
    local granted,reason=Arbiter.grant(svc.arbiter,M.SOURCE,'auto-combat activated')
    if not granted then return fail(reason,{control_owner=svc.arbiter.owner}) end
    local activated,err=Store.activate(svc.store,expected_hash)
    if not activated then
        Arbiter.revoke(svc.arbiter,M.SOURCE,'activation failed')
        return fail(err.code,err)
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
    if not Arbiter.canAct(svc.arbiter,M.SOURCE) then
        return fail('control_not_held',{control_owner=svc.arbiter.owner})
    end
    if svc.controller and svc.controller.state~='stopped' then
        return fail('already_running',{state=svc.controller.state})
    end
    local host=svc.host_factory(svc)
    if not host then return fail('execution_not_available') end
    svc.controller=Combat.new(svc.store.running,host,{strict=svc.strict,notify=function(event)
        Log.add(svc.log,{kind=event.kind,reason=event.reason,generation=event.generation,
            policy_hash=Schema.hash(svc.store.running)})
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

-- Advance the controller one action opportunity (the live pump calls this).
function M.step(svc)
    if not svc.controller then return fail('not_running') end
    if not Arbiter.canAct(svc.arbiter,M.SOURCE) then
        svc.controller:stop('control_lost')
        svc.controller=nil
        return fail('control_lost')
    end
    local step=svc.controller:onOpportunity()
    if step.action=='acted' or step.action=='paused' then
        Log.add(svc.log,{kind=step.action,reason=step.reason,rule=step.rule,talent=step.talent,
            target=step.bound_target,generation=step.generation,
            policy_hash=Schema.hash(svc.store.running)})
    end
    return ok({step=step,state=svc.controller.state,generation=svc.controller.generation})
end

function M.log(svc,limit)
    return ok({events=Log.tail(svc.log,limit or 32),status=Log.status(svc.log)})
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
    if op=='set_draft' then return M.setDraft(svc,args.policy,args.expected_hash) end
    if op=='approve' then return M.approve(svc,args.expected_hash) end
    if op=='activate' then return M.activate(svc,args.expected_hash) end
    if op=='deactivate' then return M.deactivate(svc) end
    if op=='start' then return M.start(svc) end
    if op=='stop' then return M.stop(svc,args.reason) end
    if op=='pause' then return M.pause(svc,args.reason) end
    if op=='resume' then return M.resume(svc) end
    if op=='log' then return M.log(svc,args.limit) end
    if op=='presets' then return M.presets(svc) end
    if op=='preset' then return M.preset(svc,args.name) end
    if op=='export' then return M.export(svc) end
    if op=='import' then return M.import(svc,args.document) end
    return fail('invalid_argument',{details='unknown policy op'})
end
return M
