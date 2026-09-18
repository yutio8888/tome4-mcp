-- AutoCombatService: the MCP-facing orchestration (store/arbiter/controller).
-- P3-b (TODO #63): derive the addon root from this test's own path so a bare
-- relative invocation fails loudly instead of silently testing the canonical
-- `game/addons/tome-mcp-bridge` tree from another checkout.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
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
        resources=function() return {life=90,max_life=100} end,
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
    local svc=Service.new({host_factory=fakeHost,
        log_context=function() return {tick=7,revision=3,level_instance_id='level-2'} end})
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
    check(log.events[1].rule_results~=nil and log.events[1].resources_before~=nil,
        'the log entry carries the rule trace and resource snapshot')
    check(log.events[1].tick==7 and log.events[1].revision==3 and log.events[1].level_instance_id=='level-2',
        'the log entry is tagged with world tick, revision and level instance (design 10)')
    local status=Service.handle(svc,'status',{})
    check(status.ok and type(status.last_decisions)=='table','status carries a bounded last_decisions tail')
    check(log.events[1].native_result=='ok','the action log records the native result')
    check(Service.status(svc).run.actions==1,'the run exposes a cumulative action count')
    Service.handle(svc,'stop',{})
    check(svc.arbiter.owner=='manual','stop releases the lease')
end

-- AC-08/AC-09: activation replacement and restart semantics -------------------
do
    local svc=Service.new({host_factory=fakeHost})
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local ap=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{expected_hash=ap.approved_hash})
    Service.handle(svc,'start',{})
    check(svc.controller and svc.controller.state=='running','the run started')
    -- AC-09: stop keeps the active policy; start re-acquires the lease.
    Service.handle(svc,'stop',{})
    check(svc.arbiter.owner=='manual' and svc.store.running~=nil and svc.store.active==true,
        'stop releases the lease but keeps the active policy')
    local restarted=Service.handle(svc,'start',{})
    check(restarted.ok and svc.arbiter.owner=='auto_combat',
        'start re-acquires the lease for an already-active policy')
    Service.manualInput(svc,'manual')
    check(svc.arbiter.owner=='manual' and svc.store.running~=nil,'manual input keeps the active policy')
    check(Service.handle(svc,'start',{}).ok,'start re-acquires after a manual input')
    -- AC-09: a no-visible-enemies self-stop is restartable.
    svc.controller.host.snapshot=function() return {hp_pct=80,enemy_count=0} end
    Service.step(svc)
    check(svc.arbiter.owner=='manual' and svc.store.running~=nil,'no-enemy end keeps the active policy')
    check(Service.handle(svc,'start',{}).ok,'start re-acquires after a no-enemy end')
    -- AC-08: activating a changed approved policy stops the old generation.
    local old_hash=Service.status(svc).running_hash
    local d2=Service.handle(svc,'set_draft',{policy=policy({id='p2'}),
        expected_hash=Service.status(svc).draft_hash})
    local ap2=Service.handle(svc,'approve',{expected_hash=d2.draft_hash})
    local act=Service.handle(svc,'activate',{expected_hash=ap2.approved_hash})
    check(act.ok and Service.status(svc).running_hash~=old_hash,'activation changes the running hash')
    check(svc.controller==nil,'a replacement activation stops the old controller generation')
    local started=Service.handle(svc,'start',{})
    check(started.ok and svc.controller.policy.id=='p2','start runs the replacement policy')
end

-- Round-3 follow-up #45 (Option A): a safety pause hands control back -------
do
    local svc=Service.new({host_factory=fakeHost})
    local flee=policy({safety={min_hp_pct=35,flee_below_hp_pct=25}})
    local d=Service.handle(svc,'set_draft',{policy=flee})
    local ap=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{expected_hash=ap.approved_hash})
    Service.handle(svc,'start',{})
    -- Force the flee threshold while an enemy is still visible.
    svc.controller.host.snapshot=function() return {hp_pct=10,enemy_count=1} end
    local stepped=Service.step(svc)
    check(stepped.ok and stepped.handoff==true,'a safety pause reports a handoff')
    check(svc.arbiter.owner=='manual','a safety pause releases the lease to manual')
    check(svc.controller.state=='stopped','a safety pause marks the run stopped')
    check(svc.controller.reason=='flee_below_hp_pct','the stopped run keeps the safety reason')
    local log=Service.handle(svc,'log',{limit=16})
    local pauses=0
    for _,e in ipairs(log.events) do if e.kind=='paused' then pauses=pauses+1 end end
    check(pauses==1,'exactly one pause event is logged for the transition')
    -- resume must not re-pause or log another event (the old 53-event loop).
    local resumed=Service.handle(svc,'resume',{})
    check(not resumed.ok and resumed.error.code=='not_running','resume on a handed-back run is not_running')
    local log2=Service.handle(svc,'log',{limit=16})
    local pauses2=0
    for _,e in ipairs(log2.events) do if e.kind=='paused' then pauses2=pauses2+1 end end
    check(pauses2==1,'resume writes no repeated pause event')
    -- D4: start re-acquires the lease for the still-active policy.
    check(Service.handle(svc,'start',{}).ok,'start re-acquires after a safety handoff')
    check(svc.arbiter.owner=='auto_combat','the lease is held again')
end

do
    -- no_emergency_action is the other Option-A safety pause.
    local svc=Service.new({host_factory=fakeHost})
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local ap=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{expected_hash=ap.approved_hash})
    Service.handle(svc,'start',{})
    -- Critical HP with no emergency rule left in the policy.
    svc.controller.policy.rules={}
    svc.controller.host.snapshot=function() return {hp_pct=10,enemy_count=1} end
    local stepped=Service.step(svc)
    check(stepped.ok and stepped.step.reason=='no_emergency_action','no_emergency_action pauses')
    check(stepped.handoff==true and svc.arbiter.owner=='manual' and svc.controller.state=='stopped',
        'no_emergency_action also hands control back')
end

do
    -- #46c: an explicit stop records the run boundary in the decision log.
    local svc=Service.new({host_factory=fakeHost})
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local ap=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{expected_hash=ap.approved_hash})
    Service.handle(svc,'start',{})
    Service.handle(svc,'stop',{reason='editor'})
    local log=Service.handle(svc,'log',{limit=8})
    check(log.events[1] and log.events[1].kind=='stopped' and log.events[1].reason=='editor',
        'auto stop records a stopped decision-log event')
    local before=#log.events
    Service.handle(svc,'stop',{reason='editor'})
    local log2=Service.handle(svc,'log',{limit=8})
    check(#log2.events==before,'a repeated stop writes no additional event')
end

do
    -- control_lost: the lease taken outside the controller stops and clears it.
    local svc=Service.new({host_factory=fakeHost})
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local ap=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{expected_hash=ap.approved_hash})
    Service.handle(svc,'start',{})
    svc.arbiter.owner='manual'
    local lost=Service.step(svc)
    check(not lost.ok and lost.error.code=='control_lost','a manual owner produces control_lost')
    check(svc.controller==nil,'control_lost clears the controller')
end

-- INT-04/D8: approve CASes the draft, activate CASes the approved version. ---
do
    local svc=Service.new()
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    check(Service.handle(svc,'approve',{expected_hash='deadbeef'}).error.code=='policy_conflict',
        'approve conflicts on a stale draft hash')
    local ap=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    check(ap.ok,'approve accepts the current draft hash')
    -- Change the draft so the draft hash differs from the approved hash.
    local d2=Service.handle(svc,'set_draft',{policy=policy({id='p2'}),expected_hash=d.draft_hash})
    check(Service.handle(svc,'activate',{expected_hash=d2.draft_hash}).error.code=='policy_conflict',
        'activate conflicts if given the draft hash (its CAS is the approved hash)')
    check(Service.handle(svc,'activate',{expected_hash=ap.approved_hash}).ok,
        'activate accepts the approved hash')
end

-- INT-06/D10: get returns the three versions; clear empties the draft only. ---
do
    local svc=Service.new()
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local ap=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{expected_hash=ap.approved_hash})
    local got=Service.handle(svc,'get',{})
    check(got.ok and got.draft and got.approved and got.running,'get returns the three actual versions')
    check(got.draft_hash==d.draft_hash and got.approved_hash==ap.approved_hash and got.running_hash~=nil,
        'get returns the three hashes')
    local cleared=Service.handle(svc,'clear',{})
    check(cleared.ok and svc.store.draft==nil,'clear empties the draft')
    check(svc.store.approved~=nil and svc.store.running~=nil,'clear never deletes approved or running')
end

-- Decision replay: bounded, cursor-paged, ascending -------------------------
do
    local svc=Service.new({host_factory=fakeHost,
        log_context=function() return {tick=1,revision=1,level_instance_id='level-1'} end})
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    Service.step(svc)
    Service.step(svc)
    local replay=Service.handle(svc,'replay',{limit=1})
    check(replay.ok and replay.replay==true and replay.executed==false and replay.side_effects=='none',
        'replay is a read that executes nothing')
    check(#replay.entries==1,'replay bounds the page size')
    check(replay.entries[1].seq<=replay.next_seq,'replay returns the oldest page and a cursor')
    check(replay.header and replay.header.schema and replay.header.run_state~=nil
        and replay.header.policy_hash~=nil,'replay carries a run header')
    local second=Service.handle(svc,'replay',{after_seq=replay.next_seq,limit=8})
    check(second.ok and (second.entries[1]==nil or second.entries[1].seq>replay.next_seq),
        'the replay cursor advances')
    check(Service.handle(svc,'replay',{after_seq=-1}).error.code=='invalid_argument',
        'replay validates the cursor')
    check(Service.handle(svc,'replay',{limit=999}).error.code=='invalid_argument',
        'replay bounds the page size')
end

do
    -- A pause is logged exactly once (the notify callback owns it).
    local svc=Service.new({host_factory=function()
        return {phase=function() return 'ready' end,opportunity_id=function() return 1 end,
            snapshot=function() return {hp_pct=10,enemy_count=1} end,
            enemy_ids=function() return {} end,request=function() return {status='ok'} end,
            notify=function() end}
    end})
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    Service.step(svc)
    local events=Service.handle(svc,'log',{limit=8}).events
    local pauses=0
    for _,event in ipairs(events) do if event.kind=='paused' then pauses=pauses+1 end end
    check(pauses==1,'a pause is logged exactly once')
end

do
    -- Ending because no enemy is visible returns control to the player.
    local svc=Service.new({host_factory=function()
        return {phase=function() return 'ready' end,opportunity_id=function() return 1 end,
            snapshot=function() return {hp_pct=80,enemy_count=0} end,
            enemy_ids=function() return {} end,request=function() return {status='ok'} end,
            notify=function() end}
    end})
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    Service.step(svc)
    check(svc.arbiter.owner=='manual','a no-enemy self-stop returns control')
end

-- dry_run: planning-level evaluation is a pure read --------------------------
local function readOnlyHost(state)
    return {
        phase=function() return 'ready' end,
        snapshot_meta=function() return {revision=42,level_instance_id='level-3'} end,
        snapshot=function(selector)
            if selector=='self' then
                return {hp_pct=80,enemy_count=1,binding_selector='self',bound_target=nil}
            end
            return {hp_pct=80,enemy_count=1,binding_selector=selector,
                bound_target='e1',enemy_distance=3,enemy_hp_pct=45}
        end,
        request=function() state.executed=true;error('dry run must not execute') end,
    }
end

do
    local state={executed=false}
    local svc=Service.new{dry_run_host_factory=function() return readOnlyHost(state) end}
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local dry=Service.handle(svc,'dry_run',{})
    check(dry.ok and dry.dry_run==true and dry.executed==false and dry.side_effects=='none',
        'dry_run reports that nothing ran')
    check(dry.decision=='act' and dry.rule=='beam' and dry.talent=='T_MOONLIGHT_RAY'
        and dry.action=='use_talent' and dry.target=='nearest_hostile',
        'dry_run previews the winning rule, action and talent')
    check(dry.bound_target=='e1' and dry.target_distance==3,
        'dry_run binds the same target the condition was checked against')
    check(type(dry.results)=='table' and #dry.results>=1 and dry.results[1].rule=='beam'
        and dry.results[1].result=='true',
        'dry_run returns the per-rule trace')
    check(dry.critical==false and dry.layer=='normal','dry_run reports the layer and critical flag')
    check(dry.snapshot and dry.snapshot.revision==42 and dry.snapshot.level_instance_id=='level-3',
        'dry_run carries snapshot metadata')
    check(dry.policy_source=='draft' and dry.policy_hash==d.draft_hash,
        'dry_run defaults to the draft when nothing is running or approved')
    check(state.executed==false,'dry_run never touched the executor')
    check(Service.status(svc).control_owner=='manual','dry_run does not take the lease')
end

do
    -- The running policy wins over approved/draft; an explicit policy wins over all.
    local svc=Service.new{dry_run_host_factory=function() return readOnlyHost({}) end}
    Service.handle(svc,'set_draft',{policy=policy()})
    Service.handle(svc,'approve',{})
    Service.handle(svc,'activate',{})
    check(Service.handle(svc,'dry_run',{}).policy_source=='running','dry_run prefers the running policy')
    local other=policy{id='p2'}
    local explicit=Service.handle(svc,'dry_run',{policy=other})
    check(explicit.ok and explicit.policy_source=='request','an explicit policy overrides the stored versions')
    check(Service.handle(svc,'dry_run',{policy={schema='x'}}).error.code=='invalid_policy',
        'dry_run validates the policy like any other op')
    check(Service.handle(Service.new{dry_run_host_factory=function() return readOnlyHost({}) end},
        'dry_run',{}).error.code=='no_policy','dry_run without any policy is refused')
    check(Service.handle(Service.new{},'dry_run',{policy=policy()}).error.code=='snapshot_unavailable',
        'dry_run without a read host is refused')
end

do
    -- Emergency pause and target rebinding are reported without acting.
    local low=Service.new{dry_run_host_factory=function()
        return {snapshot=function() return {hp_pct=10,enemy_count=1} end,
            snapshot_meta=function() return {revision=1,level_instance_id='level-1'} end}
    end}
    Service.handle(low,'set_draft',{policy=policy()})
    local paused=Service.handle(low,'dry_run',{})
    check(paused.decision=='pause' and paused.reason=='no_emergency_action'
        and paused.layer=='emergency' and paused.critical==true,
        'dry_run reports an emergency pause reason and layer')

    local hold=Service.new{dry_run_host_factory=function()
        return {snapshot=function() return {hp_pct=80,enemy_count=0} end}
    end}
    Service.handle(hold,'set_draft',{policy=policy()})
    check(Service.handle(hold,'dry_run',{}).reason=='no_rule_matched','dry_run reports a hold reason')

    local heal={schema='tome-auto-combat/v1',id='p1',name='p1',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={{id='heal',priority=1,when={enemy_count={ge=1}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}}}}
    local rebind=Service.new{dry_run_host_factory=function() return readOnlyHost({}) end}
    Service.handle(rebind,'set_draft',{policy=heal})
    local rebound=Service.handle(rebind,'dry_run',{})
    check(rebound.decision=='act' and rebound.binding.rebound==true
        and rebound.binding.selector=='self' and rebound.bound_target==nil,
        'dry_run re-binds a non-default selector and reports the bound target')
end

do
    -- MFT-REV-05: dry-run runs the same deny/fall-through loop as live control,
    -- so it reports the action live execution would next submit.
    local host={
        phase=function() return 'ready' end,
        snapshot_meta=function() return {revision=1,level_instance_id='level-1'} end,
        snapshot=function(selector)
            return {hp_pct=80,enemy_count=1,binding_selector=selector,bound_target='e1'}
        end,
        plan=function(attempt)
            if attempt.talent=='T_PHASE_DOOR' then return nil,{reason='landing'} end
            return {plan={kind='none',annotation={}}}
        end,
    }
    local accept={visibility='any',passability='native',hazard='any',landing='deterministic'}
    local p={schema='tome-auto-combat/v1',id='p1',name='p1',limits={max_actions_per_tick=2},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={
            {id='tp',priority=10,when={always={}},['then']={action='use_talent',
                talent='T_PHASE_DOOR',target='self',
                destination={selector='native_random',accept=accept}}},
            {id='fallback',priority=1,when={always={}},['then']={action='wait'}},
        }}
    local svc=Service.new{dry_run_host_factory=function() return host end}
    local dry=Service.handle(svc,'dry_run',{policy=p})
    check(dry.decision=='act' and dry.rule=='fallback' and dry.action=='wait',
        'dry_run falls through a planner-rejected rule to the next action')
    local rejected=0
    for _,entry in ipairs(dry.rejected or {}) do
        if entry.rule=='tp' and entry.reason=='landing' then rejected=rejected+1 end
    end
    check(rejected==1,'dry_run reports the rejected movement rule and its acceptance reason')
end

do
    -- MFT-REV-02: dry-run invokes the guard and reports the measured risk.
    local host={
        phase=function() return 'ready' end,
        snapshot_meta=function() return {revision=1,level_instance_id='level-1'} end,
        snapshot=function(selector)
            return {hp_pct=80,enemy_count=1,binding_selector=selector,bound_target='e1'}
        end,
        guard=function()
            return {action='reject',reason='selffire_risk',
                detail={measurement=90,threshold=0,risk='friendly',phase='instant'}}
        end,
    }
    local p={schema='tome-auto-combat/v1',id='p1',name='p1',limits={max_actions_per_tick=2},
        safety={min_hp_pct=35,max_selffire_risk=0},targeting={default='nearest_hostile'},
        rules={{id='beam',priority=10,when={always={}},
            ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}}}}
    local dry=Service.handle(Service.new{dry_run_host_factory=function() return host end},
        'dry_run',{policy=p})
    local risk=nil
    for _,entry in ipairs(dry.rejected or {}) do
        if entry.rule=='beam' then risk=entry.risk end
    end
    check(risk and risk.measurement==90 and risk.threshold==0,
        'dry_run surfaces the guard risk measurement and threshold')
end

do
    -- MFT-REV-05(a): the instant cap counts only successful instants, not
    -- rejected candidates. Dry-run must not charge an instant slot for a
    -- guard-rejected rule before the permitted one.
    local host={
        phase=function() return 'ready' end,
        snapshot_meta=function() return {revision=1,level_instance_id='level-1'} end,
        snapshot=function(selector)
            return {hp_pct=80,enemy_count=1,binding_selector=selector,bound_target='e1'}
        end,
        guard=function(attempt)
            if attempt.rule=='first' then
                return {action='reject',reason='selffire_risk',
                    detail={measurement=100,threshold=0}}
            end
            return nil
        end,
    }
    local p={schema='tome-auto-combat/v1',id='p1',name='p1',
        limits={max_actions_per_tick=2,max_instant_per_tick=1},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={
            {id='first',priority=10,when={always={}},['then']={action='use_talent',
                talent='T_MOONLIGHT_RAY',target='nearest_hostile'}},
            {id='second',priority=5,when={always={}},['then']={action='use_talent',
                talent='T_SEARING_LIGHT',target='nearest_hostile'}},
        }}
    local dry=Service.handle(Service.new{dry_run_host_factory=function() return host end},
        'dry_run',{policy=p})
    check(dry.decision=='act' and dry.rule=='second',
        'dry_run does not charge an instant slot for a guard-rejected candidate (MFT-REV-05a)')
end

do
    -- MFT-REV-05(b): a multi-prompt target plan pauses in dry-run, exactly as
    -- live control does, instead of deny+fall-through.
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local host={
        phase=function() return 'ready' end,
        snapshot_meta=function() return {revision=1,level_instance_id='level-1'} end,
        snapshot=function(selector)
            return {hp_pct=80,enemy_count=1,binding_selector=selector,bound_target='e1'}
        end,
        plan=function() return nil,{reason='unsupported_target_plan',count=2} end,
    }
    local p={schema='tome-auto-combat/v1',id='p1',name='p1',limits={max_actions_per_tick=2},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={{id='kite',priority=1,when={always={}},['then']={action='move',
            target='nearest_hostile',destination={selector='away',anchor='bound_target',
                accept=accept}}}}}
    local dry=Service.handle(Service.new{dry_run_host_factory=function() return host end},
        'dry_run',{policy=p})
    check(dry.decision=='pause' and dry.reason=='unsupported_target_plan',
        'dry_run pauses on a multi-prompt plan like live (MFT-REV-05b)')
end

do
    -- MFT-REV-03 (Option A): dry-run binds an actor step selector when the
    -- policy declares no action/default selector.
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local host={
        phase=function() return 'ready' end,
        snapshot_meta=function() return {revision=1,level_instance_id='level-1'} end,
        snapshot=function(selector)
            local bound='e1'
            if selector=='self' or selector==nil then bound=nil end
            return {hp_pct=80,enemy_count=1,binding_selector=selector,bound_target=bound}
        end,
        plan=function() return {plan={kind='actor',annotation={landing={kind='bounded'}}}} end,
    }
    local p={schema='tome-auto-combat/v1',id='p1',name='p1',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},
        rules={{id='rush',priority=1,when={always={}},['then']={action='use_talent',talent='T_RUSH',
            target_plan={{request='actor',selector='nearest_hostile'}},
            destination={selector='native_landing',anchor='bound_target',accept=accept}}}}}
    local dry=Service.handle(Service.new{dry_run_host_factory=function() return host end},
        'dry_run',{policy=p})
    check(dry.decision=='act' and dry.rule=='rush' and dry.binding.selector=='nearest_hostile'
        and dry.bound_target=='e1',
        'dry_run binds the declared actor step selector with no action selector (MFT-REV-03)')
end

do
    -- MFT-REV-07: the production controller -> PolicyLog -> service log/replay
    -- path keeps the accepted movement annotation and permitted-risk detail.
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local host={
        phase=function() return 'ready' end,
        opportunity_id=function() return 1 end,
        snapshot=function(selector)
            return {hp_pct=80,enemy_count=1,binding_selector=selector,bound_target='e1'}
        end,
        enemy_ids=function() return {} end,
        notify=function() end,
        plan=function() return {plan={kind='step',direction=4,
            annotation={landing={kind='deterministic',x=3,y=2},visible=true,
                known_passable=true,known_hazard='unknown'}}} end,
        guard=function() return {action='permit',detail={measurement=40,threshold=50,
            phase='instant',provenance={selffire='explicit'}}} end,
        request=function() return {status='ok',energy_spent=1000} end,
    }
    local p={schema='tome-auto-combat/v1',id='p1',name='p1',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={{id='kite',priority=1,when={always={}},['then']={action='move',
            target='nearest_hostile',destination={selector='away',anchor='bound_target',
                accept=accept}}}}}
    local svc=Service.new{host_factory=function() return host end}
    local set=Service.handle(svc,'set_draft',{policy=p})
    check(set.ok,'the move policy is accepted')
    Service.handle(svc,'approve',{})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    local step=Service.step(svc)
    check(step.ok and step.step and step.step.action=='acted','the production controller acts')
    local log=Service.handle(svc,'log',{limit=8})
    local movement,risk
    for _,event in ipairs(log.events or {}) do
        if event.kind=='acted' then movement=event.movement;risk=event.risk end
    end
    check(movement and movement.landing and movement.landing.kind=='deterministic',
        'tome.policy_log carries the movement annotation (MFT-REV-07)')
    check(risk and risk.measurement==40 and risk.threshold==50,
        'tome.policy_log carries the permitted-risk detail (MFT-REV-07)')
    local replay=Service.handle(svc,'replay',{limit=8})
    local replayRisk
    for _,event in ipairs(replay.entries or {}) do
        if event.kind=='acted' then replayRisk=event.risk end
    end
    check(replayRisk and replayRisk.measurement==40,
        'tome.policy replay carries the permitted-risk detail (MFT-REV-07)')
end

do
    -- A native-activity rule is previewed without executing it.
    local camp={schema='tome-auto-combat/v1',id='p1',name='p1',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={{id='camp',priority=1,when={always={}},['then']={action='rest',max_turns=5}}}}
    local svc=Service.new{dry_run_host_factory=function() return readOnlyHost({}) end}
    local dry=Service.handle(svc,'dry_run',{policy=camp})
    check(dry.ok and dry.decision=='act' and dry.action=='rest' and dry.max_turns==5,
        'dry_run previews a rest activity and its max_turns')
    check(dry.executed==false and dry.side_effects=='none','a rest dry run still executes nothing')
end

-- Presets, import/export and character persistence.
do
    local svc=Service.new()
    local presets=Service.handle(svc,'presets',{})
    check(presets.ok and #presets.names>=1,'the service lists the built-in presets')
    local preset=Service.handle(svc,'preset',{name='anorithil_p1a'})
    check(preset.ok and preset.policy,'a preset can be fetched as a policy')
    check(Service.handle(svc,'preset',{name='missing'}).error.code=='unknown_preset','an unknown preset is refused')
    local set=Service.handle(svc,'set_draft',{policy=preset.policy})
    check(set.ok,'a preset can become the draft')
    local document=Service.handle(svc,'export',{}).document
    check(type(document)=='string','the draft exports to a document')
    local imported=Service.handle(Service.new(),'import',{document=document})
    check(imported.ok and imported.hash==set.draft_hash,'the document imports to the same hash')
    Service.handle(svc,'approve',{})
    Service.handle(svc,'activate',{})
    local state=Service.saveState(svc)
    check(state.draft~=nil and state.approved~=nil,'the save state carries the policy')
    local restored=Service.new()
    check(Service.loadState(restored,state),'loading a character restores its policy')
    check(restored.store.approved~=nil and restored.store.running==nil and restored.arbiter.owner=='manual',
        'loading never restores the running state or control')
    check(Service.loadState(restored,{approved={schema='bad'}})==true and restored.store.approved~=nil,
        'an invalid stored policy is ignored')
end
-- P0/F4: a bounded native abort records a typed event, stops the run and hands
-- the lease back to the player.
do
    local svc=Service.new({host_factory=fakeHost})
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local ap=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{expected_hash=ap.approved_hash})
    Service.handle(svc,'start',{})
    Service.step(svc)
    local entry=Service.nativeAbort(svc,{code='native_timeout',rule='beam',action='use_talent',
        talent='T_MOONLIGHT_RAY',target='e1',elapsed_ticks=3,elapsed_frames=22})
    check(entry and entry.kind=='native_aborted' and entry.reason=='native_timeout',
        'the native abort records the typed controller event')
    check(svc.arbiter.owner=='manual','the native abort releases the auto-combat lease')
    check(svc.controller.state=='stopped' and svc.controller.reason=='native_timeout',
        'the native abort stops the run with the typed reason')
    local log=Service.handle(svc,'log',{limit=8})
    local found
    for _,event in ipairs(log.events or {}) do
        if event.kind=='native_aborted' then found=event end
    end
    check(found and found.reason=='native_timeout' and found.talent=='T_MOONLIGHT_RAY'
        and found.target=='e1' and found.elapsed_frames==22,
        'the typed abort reaches the service policy log with action/talent/target/elapsed')
end

do
    -- P2-1: a deterministic landing refused natively is retried with an
    -- alternative; the movement_retry event reaches the service policy log with
    -- the underlying native code, and the run still acts.
    local attempts=0
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local function plan(attempt)
        local exclude=attempt.exclude or {}
        if not exclude['4,2'] then
            return {plan={kind='step',direction=9,x=4,y=2,
                annotation={landing={kind='deterministic',x=4,y=2}}}}
        end
        return {plan={kind='step',direction=6,x=4,y=3,
            annotation={landing={kind='deterministic',x=4,y=3}}}}
    end
    local host={phase=function() return 'ready' end,opportunity_id=function() return 1 end,
        snapshot=function() return {hp_pct=80,enemy_count=1,binding_selector='nearest_hostile'} end,
        enemy_ids=function() return {} end,notify=function() end,plan=plan,
        request=function(attempt)
            attempts=attempts+1
            local landing=attempt.plan and (attempt.plan.x..','..attempt.plan.y)
            if landing=='4,2' then return {status='rejected',code='blocked',energy_spent=0} end
            return {status='ok',energy_spent=1000}
        end}
    local p=policy({limits={max_actions_per_tick=2},rules={
        {id='approach',priority=10,when={always={}},
            ['then']={action='move',target='nearest_hostile',
                destination={selector='toward',anchor='bound_target',accept=accept}}}}})
    local svc=Service.new{host_factory=function() return host end}
    local d=Service.handle(svc,'set_draft',{policy=p})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    local stepped=Service.step(svc)
    check(stepped.ok and stepped.step.action=='acted' and attempts==2,
        'the service retries a refused deterministic landing with an alternative')
    local log=Service.handle(svc,'log',{limit=8})
    local found
    for _,event in ipairs(log.events or {}) do
        if event.kind=='movement_retry' then found=event end
    end
    check(found and found.rule=='approach' and found.native_result=='blocked',
        'the movement_retry event reaches the policy log with the native code')
    -- N1: the client-visible retry entry must carry the refused landing, not
    -- only the native result, so a client can reconstruct the blocked cell.
    check(found.landing=='4,2','the movement_retry event keeps the refused landing (N1)')
end

do
    -- D-1 (P1, round anor-reg-01): an emergency action natively refused on
    -- cooldown must not livelock through the service. The run keeps acting (each
    -- action advances the world tick so the native cooldown recovers) and the
    -- emergency action is used again; there is no repeated deny -> pause loop.
    local cooldown=3
    local heal_used=false
    local host={phase=function() return 'ready' end,opportunity_id=function() return 1 end,
        snapshot=function(selector) return {hp_pct=30,enemy_count=1,binding_selector=selector} end,
        enemy_ids=function() return {} end,notify=function() end,
        request=function(attempt)
            if attempt.rule=='heal' then
                if cooldown>0 then
                    return {status='rejected',code='native_rejected',energy_spent=false,
                        missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=cooldown,required=0}},
                        native_message='Healing Light is still on cooldown for '..cooldown..' turns.'}
                end
                heal_used=true
                return {status='ok',energy_spent=1000}
            end
            cooldown=math.max(0,cooldown-1)
            return {status='ok',energy_spent=1000}
        end}
    local p=policy({limits={max_actions_per_tick=2},mode={on_low_hp='emergency_only'},rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
        {id='attack',priority=40,when={always={}},
            ['then']={action='attack',target='nearest_hostile'}}}})
    local svc=Service.new{host_factory=function() return host end}
    local d=Service.handle(svc,'set_draft',{policy=p})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    local acted,paused=0,0
    for _=1,6 do
        local stepped=Service.step(svc)
        if stepped.ok then
            if stepped.step.action=='acted' then acted=acted+1
            elseif stepped.step.action=='paused' then paused=paused+1 end
        end
        svc.controller.host.opportunity_id=function() return (svc.controller.opportunity_id or 1)+1 end
    end
    check(acted>=3,'the service keeps acting while the emergency action is on cooldown (D-1)')
    check(paused==0,'no emergency-deny pause loop in the service (D-1)')
    check(heal_used,'the emergency action is used again once the cooldown recovered (D-1)')
end

do
    -- R-1 (P1, round anor-reg-01 fix2): the schema-valid max_actions_per_tick=1
    -- boundary (also the assistant-import default). A settled no-energy reject
    -- must not consume the only budget slot: the same opportunity falls through
    -- to the fallback, the world keeps ticking and the cooldown recovers. The
    -- old contract paused budget_exhausted with the lease held — a frozen loop.
    local cooldown=3
    local heal_used=false
    local host={phase=function() return 'ready' end,opportunity_id=function() return 1 end,
        snapshot=function(selector) return {hp_pct=30,enemy_count=1,binding_selector=selector} end,
        enemy_ids=function() return {} end,notify=function() end,
        request=function(attempt)
            if attempt.rule=='heal' then
                if cooldown>0 then
                    return {status='rejected',code='native_rejected',energy_spent=false,
                        missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=cooldown,required=0}}}
                end
                heal_used=true
                return {status='ok',energy_spent=1000}
            end
            cooldown=math.max(0,cooldown-1)
            return {status='ok',energy_spent=1000}
        end}
    local p=policy({limits={max_actions_per_tick=1},mode={on_low_hp='emergency_only'},rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
        {id='wait',priority=40,when={always={}},['then']={action='wait'}}}})
    local svc=Service.new{host_factory=function() return host end}
    local d=Service.handle(svc,'set_draft',{policy=p})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    local acted,paused=0,0
    for _=1,6 do
        local stepped=Service.step(svc)
        if stepped.ok then
            if stepped.step.action=='acted' then acted=acted+1
            elseif stepped.step.action=='paused' then paused=paused+1 end
        end
        svc.controller.host.opportunity_id=function() return (svc.controller.opportunity_id or 1)+1 end
    end
    check(acted>=3,'the limit-1 service run falls through and keeps acting (R-1)')
    check(paused==0,'no budget_exhausted pause loop at the limit-1 boundary (R-1)')
    check(heal_used,'the limit-1 emergency action is used again once the cooldown recovered (R-1)')
    check(svc.arbiter.owner=='auto_combat','the lease is retained while the run keeps acting (R-1)')
end

do
    -- R-1: with nothing applicable after a settled reject, the run stops with
    -- the typed refusal and the lease is released — no held-lease frozen loop,
    -- and `resume` cannot replay the same rejected action.
    local host={phase=function() return 'ready' end,opportunity_id=function() return 1 end,
        snapshot=function(selector) return {hp_pct=30,enemy_count=1,binding_selector=selector} end,
        enemy_ids=function() return {} end,notify=function() end,
        request=function(attempt)
            return {status='rejected',code='native_rejected',energy_spent=false,
                missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=7,required=0}}}
        end}
    local p=policy({limits={max_actions_per_tick=1},mode={on_low_hp='emergency_only'},rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}}}})
    local svc=Service.new{host_factory=function() return host end}
    local d=Service.handle(svc,'set_draft',{policy=p})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    local stepped=Service.step(svc)
    check(stepped.ok and stepped.step.action=='stopped' and stepped.step.reason=='action_denied',
        'the refusal terminal stops with the typed reason, never budget_exhausted (R-1)')
    check(svc.arbiter.owner=='manual' and svc.controller.state=='stopped',
        'the refusal stop releases the lease instead of freezing it (R-1)')
    local resumed=Service.handle(svc,'resume',{})
    check(not resumed.ok and resumed.error.code=='not_running',
        'resume cannot replay the rejected action on a handed-back run (R-1)')
    check(Service.handle(svc,'start',{}).ok,'start re-acquires after the refusal handoff (R-1)')
end

do
    -- R-1: budget_exhausted keeps its honest meaning — it fires only after max
    -- completed (charged) actions in one opportunity, and because charged
    -- actions advanced the world, that pause retains the lease (no frozen loop:
    -- time passed, so resume makes progress).
    local host=fakeHost()  -- opportunity_id fixed at 1: a repeated opportunity
    local p=policy({limits={max_actions_per_tick=1}})
    local svc=Service.new{host_factory=function() return host end}
    local d=Service.handle(svc,'set_draft',{policy=p})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    local first=Service.step(svc)
    check(first.ok and first.step.action=='acted','the first charged action completes')
    local second=Service.step(svc)
    check(second.ok and second.step.action=='paused' and second.step.reason=='budget_exhausted',
        'the limit-1 budget pauses after the completed action (honest budget_exhausted)')
    check(svc.arbiter.owner=='auto_combat',
        'a charged-action budget pause retains the lease (the world advanced)')
end

do
    -- D-2: the auto denied policy-log event carries the structured cooldown
    -- detail and the native message (bounded, type-guarded).
    local host={phase=function() return 'ready' end,opportunity_id=function() return 1 end,
        snapshot=function(selector) return {hp_pct=30,enemy_count=1,binding_selector=selector} end,
        enemy_ids=function() return {} end,notify=function() end,
        request=function(attempt)
            return {status='rejected',code='native_rejected',energy_spent=false,
                missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=7,required=0}},
                hint='talent on cooldown; wait for the listed turns before retrying',
                native_message='Healing Light is still on cooldown for 7 turns.'}
        end}
    local p=policy({limits={max_actions_per_tick=1},mode={on_low_hp='emergency_only'},rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}}}})
    local svc=Service.new{host_factory=function() return host end}
    local d=Service.handle(svc,'set_draft',{policy=p})
    Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{})
    Service.handle(svc,'start',{})
    Service.step(svc)
    local log=Service.handle(svc,'log',{limit=16})
    local denied
    for _,event in ipairs(log.events or {}) do
        if event.kind=='denied' then denied=event end
    end
    check(denied and denied.reason=='native_rejected','the denied event is logged (D-2)')
    check(denied.missing and denied.missing[1] and denied.missing[1].kind=='cooldown'
        and denied.missing[1].remaining==7 and denied.missing[1].talent=='T_HEALING_LIGHT',
        'the policy log carries the structured cooldown missing (D-2)')
    check(denied.native_message=='Healing Light is still on cooldown for 7 turns.',
        'the policy log carries the native message (D-2)')
    check(denied.hint=='talent on cooldown; wait for the listed turns before retrying',
        'the policy log carries the hint (D-2)')
    -- P3-c: `landing` is guarded by `boundedString(event.landing,64)` in
    -- `PolicyLog.add`, so a hostile policy cannot grow the ring with a table or
    -- any other non-string value, and an over-long string is truncated rather
    -- than stored whole.
    local Log=require 'mod.auto_combat.PolicyLog'
    local ring=Log.new(4)
    Log.add(ring,{kind='movement_retry',landing={huge='table'}})
    check(Log.tail(ring,1)[1].landing==nil,'a non-string landing is dropped by PolicyLog (P3-c)')
    Log.add(ring,{kind='movement_retry',landing=42})
    check(Log.tail(ring,1)[1].landing==nil,'a non-string (number) landing is dropped by PolicyLog (P3-c)')
    Log.add(ring,{kind='movement_retry',landing=('x'):rep(200)})
    check(Log.tail(ring,1)[1].landing==('x'):rep(64),
        'an over-long landing is truncated to 64 characters by PolicyLog (P3-c)')
    Log.add(ring,{kind='movement_retry',landing='4,2'})
    check(Log.tail(ring,1)[1].landing=='4,2','a bounded string landing is kept intact (P3-c)')
    Log.add(ring,{kind='denied',missing='not-a-table'})
    check(Log.tail(ring,1)[1].missing==nil,'a non-table missing is dropped by PolicyLog (D-2)')
end

do
    -- D-4: the status log tail is coherent - the ring extent and the returned
    -- window are both reported so a bounded tail can never be mistaken for the
    -- whole ring.
    local svc=Service.new()
    local Log=require 'mod.auto_combat.PolicyLog'
    for i=1,94 do
        Log.add(svc.log,{kind='acted',rule='r'..i,generation=1})
    end
    local status=Service.handle(svc,'status',{})
    check(status.log.count==94 and status.log.first_seq==1 and status.log.last_seq==94,
        'the ring extent is reported')
    check(status.log.window and status.log.window.count==32 and status.log.window.last_seq==94,
        'the status log window reports the bounded tail actually available (D-4)')
    check(status.log.window.first_seq==63,
        'the window first_seq matches the oldest returned event, not the ring (D-4)')
    local log=Service.handle(svc,'log',{limit=5})
    check(log.events[1].seq==94 and log.events[#log.events].seq==90,
        'log returns the newest-first bounded tail')
    check(log.status.window and log.status.window.first_seq==90 and log.status.window.last_seq==94,
        'the log status window describes the returned events (D-4)')
    -- RR-1 / R-2: the OLDEST-FIRST `replay` path must report the same coherent
    -- window as the newest-first `log`/`status` paths (`first_seq<=last_seq`),
    -- and the window extent must be exactly the returned slice, not the ring.
    local replay=Service.handle(svc,'replay',{after_seq=60,limit=5})
    check(replay.ok and #replay.entries==5 and replay.entries[1].seq==61
        and replay.entries[#replay.entries].seq==65,
        'replay returns the oldest-first bounded slice (RR-1)')
    check(replay.status.window and replay.status.window.count==5,
        'replay reports a window for the returned slice (RR-1)')
    check(replay.status.window.first_seq==61 and replay.status.window.last_seq==65,
        'the replay window extent is the returned slice, not the ring (RR-1)')
    check(replay.status.window.first_seq<=replay.status.window.last_seq,
        'the oldest-first replay window keeps first_seq<=last_seq (RR-1)')
    -- The same bounded page read newest-first must agree on the extent, so the
    -- order never changes what the window means (R-2).
    local newest=Service.handle(svc,'log',{limit=5})
    check(newest.events[1].seq==94 and newest.events[#newest.events].seq==90,
        'log still returns the newest-first bounded tail (RR-1)')
    check(newest.status.window.first_seq==90 and newest.status.window.last_seq==94,
        'the newest-first window agrees with the oldest-first window extent semantics (RR-1)')
end
print('Auto-combat service: '..checks..' checks passed')