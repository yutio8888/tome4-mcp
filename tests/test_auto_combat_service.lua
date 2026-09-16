-- AutoCombatService: the MCP-facing orchestration (store/arbiter/controller).
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Service=require 'mod.auto_combat.AutoCombatService'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local function policy(overrides)
    local p={schema='tome-auto-combat/v1',id='p1',name='p1',
        limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},
        targeting={default='nearest_hostile'},
        rules={{id='beam',priority=1,when={enemy_count={ge=1}},
            ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}}}}
    for k,v in pairs(overrides or {}) do p[k]=v end
    return p
end

local function fakeHost()
    return {phase=function() return 'ready' end,opportunity_id=function() return 1 end,
        snapshot=function() return {hp_pct=80,enemy_count=1} end,
        enemy_ids=function() return {} end,request=function() return {status='ok'} end,
        notify=function() end}
end

-- validate/set_draft/approve/activate -----------------------------------------
do
    local svc=Service.new()
    local invalid=Service.handle(svc,'validate',{policy={schema='tome-auto-combat/v1'}})
    check(not invalid.ok and invalid.error.code=='invalid_policy','an invalid policy is refused')
    local valid=Service.handle(svc,'validate',{policy=policy()})
    check(valid.ok and valid.hash,'a valid policy validates and hashes')
    local draft=Service.handle(svc,'set_draft',{policy=policy()})
    check(draft.ok and draft.draft_hash,'a valid policy becomes the draft')
    local conflict=Service.handle(svc,'set_draft',{policy=policy(),expected_hash='deadbeef'})
    check(not conflict.ok and conflict.error.code=='policy_conflict','a stale draft write conflicts')
    check(Service.handle(svc,'activate',{expected_hash=draft.draft_hash}).error.code=='not_approved',
        'activation requires an approved policy')
    local approved=Service.handle(svc,'approve',{expected_hash=draft.draft_hash})
    check(approved.ok,'the draft is approved')
    local activated=Service.handle(svc,'activate',{expected_hash=approved.approved_hash})
    check(activated.ok and activated.running_hash,'activation promotes the approved policy')
    check(Service.status(svc).control_owner=='auto_combat','activation requests the lease')
end

-- start requires the running version and a host --------------------------------
do
    local svc=Service.new()
    check(Service.handle(svc,'start',{}).error.code=='not_activated','start requires an activated policy')
    local svc2=Service.new()
    local d=Service.handle(svc2,'set_draft',{policy=policy()})
    Service.handle(svc2,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc2,'activate',{})
    check(Service.handle(svc2,'start',{}).error.code=='execution_not_available',
        'without a host the run is not wired')
end

-- control arbitration ----------------------------------------------------------
do
    local svc=Service.new({host_factory=fakeHost})
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    local started=Service.handle(svc,'start',{})
    check(started.ok and started.state=='running','an activated policy starts when a host is available')
    local step=Service.handle(svc,'start',{})
    check(step.error.code=='already_running','a second start is refused')
    -- A manual input takes the lease and stops the run.
    Service.manualInput(svc,'player input')
    check(svc.arbiter.owner=='manual' and svc.controller==nil,'manual input revokes control')
    local resumed=Service.handle(svc,'resume',{})
    check(resumed.error.code=='not_running','resume fails while the lease is manual')
    -- Re-activate to regain control.
    local d2=Service.handle(svc,'set_draft',{policy=policy(),expected_hash=Service.status(svc).draft_hash})
    local approved=Service.handle(svc,'approve',{expected_hash=d2.draft_hash})
    local activated=Service.handle(svc,'activate',{expected_hash=approved.approved_hash})
    check(activated.ok,'the plugin can be re-activated after a manual takeover')
    Service.handle(svc,'start',{})
    local stepped=Service.step(svc)
    check(stepped.ok and stepped.step.action=='acted','the pump advances one opportunity')
    local log=Service.handle(svc,'log',{limit=4})
    check(log.ok and #log.events>=1 and log.events[1].kind=='acted','the service log records the step')
    Service.handle(svc,'stop',{})
    check(svc.arbiter.owner=='manual','stop releases the lease')
end

print('Auto-combat service: '..checks..' checks passed')
