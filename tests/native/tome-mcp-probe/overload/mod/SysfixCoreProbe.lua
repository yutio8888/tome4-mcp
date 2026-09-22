-- Optional coordinator-owned SYSFIX fixture. Never auto-runs or manages the
-- game process. Call prepareLocalClear before a real save, then verifyReload
-- after loading that save. Production Runtime/service/store do all mutations.
local M={}
local function record(stage)
    local Runtime=require 'mod.mcp_bridge.Runtime'
    local live=assert(Runtime.autoCombatHandle(game,'get',{}))
    local saved=assert(game.player.auto_combat_policy)
    assert(live.ok and live.draft==nil and saved.draft==nil,'cleared draft returned')
    assert(live.approved and live.approved.id=='sysfix-approved','approved policy lost')
    assert(saved.approved and saved.approved.id=='sysfix-approved','saved approved policy lost')
    for _,key in ipairs{'socket','queue','controller','control_token','lease','arbiter','invocation'} do
        assert(saved[key]==nil,'runtime state persisted: '..key)
    end
    local out={stage=stage,live_draft_empty=true,saved_draft_empty=true,approved_id=live.approved.id,
        control_owner=Runtime.autoCombatStatus(game).control_owner,
        execution_enabled=Runtime.autoCombatExecutionEnabled(game)}
    print('[SysfixCoreProbe] '..require('mod.mcp_bridge.Json').encode(out))
    return out
end
function M.prepareLocalClear()
    local Runtime=require 'mod.mcp_bridge.Runtime'
    local function policy(id)
        return {schema='tome-auto-combat/v1',id=id,name=id,
            rules={{id='wait',priority=1,when={always={}},['then']={action='wait'}}}}
    end
    assert(Runtime.autoCombatHandle(game,'set_draft',{policy=policy('sysfix-approved')}).ok)
    assert(Runtime.autoCombatHandle(game,'approve',{}).ok)
    assert(Runtime.autoCombatHandle(game,'set_draft',{policy=policy('sysfix-clear-me')}).ok)
    assert(game.player.auto_combat_policy.draft.id=='sysfix-clear-me')
    assert(Runtime.autoCombatHandle(game,'clear',{}).ok)
    return record('before_native_save')
end
function M.verifyReload()
    local out=record('after_native_reload')
    local Runtime=require 'mod.mcp_bridge.Runtime'
    local state=Runtime.autoCombatStatus(game)
    assert(not state.active and not state.run,'load resumed automatic run')
    return out
end
return M
