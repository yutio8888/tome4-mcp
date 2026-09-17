-- GPL-3.0-or-later. Controller host adapter.
--
-- Turns the injected audited reads and the injected executor into the host
-- contract AutoCombat expects. Keeping this thin and dependency-free means the
-- live Runtime can supply reads built from Observer/ActorCombat and an executor
-- built on Actions.execute, while unit tests supply fakes -- the same code path.
local Snapshot=require 'mod.auto_combat.PolicySnapshot'
local M={}

-- opts (all functions unless noted):
--   policy                    the running policy (for selector defaults)
--   phase()                   'ready' | 'settling' | 'native_pending' | 'waiting_player'
--   opportunity_id()          number that changes only on a new action opportunity
--   enemy_ids()               array of stable visible hostile ids (strict mode)
--   origin()                  {x,y}
--   hp_pct()                  number|nil
--   resource_pct(name)        number|nil
--   resource_value(name)      number|nil
--   talent_known(id)          boolean|nil
--   cooldown_ready(id)        boolean|nil
--   has_effect(effect,who)    boolean|nil
--   computed(field)           boolean|nil
--   hostiles()                array of {id,x,y,hp_pct}
--   execute(attempt)          -> {status,code,energy_spent}
--   notify(event)             optional
function M.new(opts)
    local host={}
    local function call(name,...)
        local fn=opts[name]
        if type(fn)~='function' then return nil end
        return fn(...)
    end
    host.phase=function() return call('phase') or 'settling' end
    host.opportunity_id=function() return call('opportunity_id') end
    host.enemy_ids=function() return call('enemy_ids') end
    host.notify=opts.notify
    -- Expose the reads the controller consults outside the snapshot (sustain
    -- maintenance needs the desired-state check and the known check).
    host.sustain_on=opts.sustain_on
    host.resources=opts.resources
    host.talent_known=opts.talent_known
    -- Reads the controller consults outside the snapshot (D6 sustain gating).
    host.resource_pct=opts.resource_pct
    host.resource_value=opts.resource_value
    -- Pre-execution safety guard (AC-03/D1/D2). Only the live host provides it.
    host.guard=opts.guard
    -- Optional {revision, level_instance_id} metadata for dry-run diagnostics.
    host.snapshot_meta=opts.snapshot_meta
    host.snapshot=function(selector) return Snapshot.build(opts,opts.policy,selector) end
    host.request=function(attempt)
        local execute=opts.execute
        if type(execute)~='function' then return {status='error',code='execution_not_available'} end
        local ok,outcome=pcall(execute,attempt)
        if not ok then return {status='error',code='execution_error',message=tostring(outcome)} end
        if type(outcome)~='table' then return {status='error',code='invalid_executor_result'} end
        if outcome.status==nil then return {status=outcome.ok and 'ok' or 'rejected',code=outcome.code,
            energy_spent=outcome.energy_spent} end
        return outcome
    end
    return host
end
return M
