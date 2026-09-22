-- Opt-in SYSFIX fixture, enabled only by tests/native/run.py --sysfix-core.
-- Birth prepares the real local store; reload verifies it without mutation.
-- The runner owns native Ctrl+S and loading that character in a new process.
local M={}
function M.enabled()
    return config and config.settings and config.settings.tome_mcp_sysfix_core_probe==true
end
local function plainData(value,seen)
    local kind=type(value)
    if kind~='table' then
        assert(kind=='nil' or kind=='boolean' or kind=='string' or kind=='number',
            'runtime handle in saved policy: '..kind)
        return
    end
    assert(getmetatable(value)==nil,'metatable in saved policy')
    assert(not seen[value],'cycle in saved policy')
    seen[value]=true
    for key,entry in pairs(value) do plainData(key,seen); plainData(entry,seen) end
    seen[value]=nil
end
local function record(stage)
    local Runtime=require 'mod.mcp_bridge.Runtime'
    local Codec=require 'mod.auto_combat.PolicyCodec'
    local live=assert(Runtime.autoCombatHandle(game,'get',{}))
    local saved=assert(game.player.auto_combat_policy)
    assert(live.ok and live.draft==nil and saved.draft==nil,'cleared draft returned')
    assert(live.approved and live.approved.id=='sysfix-approved','approved policy lost')
    assert(saved.approved and saved.approved.id=='sysfix-approved','saved approved policy lost')
    assert(saved.format==3,'unexpected policy save format')
    for key in pairs(saved) do
        assert(key=='format' or key=='approved','runtime or extra state persisted: '..tostring(key))
    end
    plainData(saved,{})
    local live_bytes=assert(Codec.encode(live.approved))
    local saved_bytes=assert(Codec.encode(saved.approved))
    assert(live_bytes==saved_bytes,'saved and live approved policies differ')
    local state=assert(Runtime.autoCombatStatus(game))
    assert(state.ok and not state.active and state.run==nil and live.running==nil,
        'automatic policy/run unexpectedly active')
    assert(state.control_owner=='manual','automatic/remote control survived into fixture boundary')
    assert(Runtime.autoCombatExecutionEnabled(game)==false,'execution unexpectedly enabled')
    -- Entity.loaded assigns a fresh uid on every load. Player.puuid is the
    -- persistent character identity; the runner also verifies the copied save.
    assert(type(game.player.puuid)=='string' and #game.player.puuid>0,'missing persistent character UUID')
    assert(type(game.save_name)=='string' and #game.save_name>0,'missing native save name')
    local out={kind='sysfix_core',stage=stage,player_uid=game.player.uid,
        character_uuid=game.player.puuid,save_name=game.save_name,
        live_draft_empty=true,saved_draft_empty=true,approved_id=live.approved.id,
        approved_live_bytes=live_bytes,approved_saved_bytes=saved_bytes,
        runtime_handles_absent=true,save_format=saved.format,
        active=false,run_present=false,control_owner=state.control_owner,execution_enabled=false}
    require('mod.MCPProbe').emit(out)
    return out
end
function M.prepareLocalClear()
    assert(M.enabled(),'SYSFIX fixture must be explicitly enabled')
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
    assert(M.enabled(),'SYSFIX fixture must be explicitly enabled')
    return record('after_native_reload')
end
return M
