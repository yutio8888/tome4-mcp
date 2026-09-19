-- Contract tests for the P1a control/execution layer: ControlArbiter (control is
-- separate from certification), PolicyStore (draft/approved/running hashes), and
-- the AutoCombat state machine (start-when-ready, budget, native_pending,
-- pause/resume generations, strict resume).
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
local ControlArbiter=require 'mod.auto_combat.ControlArbiter'
local PolicyStore=require 'mod.auto_combat.PolicyStore'
local AutoCombat=require 'mod.auto_combat.AutoCombat'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local function policy(overrides)
    local p={
        schema='tome-auto-combat/v1',id='p1',name='p1',
        limits={max_actions_per_tick=2},
        safety={min_hp_pct=35,flee_below_hp_pct=25,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        rules={
            {id='beam',priority=50,when={enemy_count={ge=1}},
                ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}},
            {id='attack',priority=40,when={enemy_count={ge=1}},
                ['then']={action='attack',target='nearest_hostile'}},
        },
    }
    for k,v in pairs(overrides or {}) do p[k]=v end
    return p
end

-- 1. ControlArbiter ----------------------------------------------------------
do
    local a=ControlArbiter.new()
    check(ControlArbiter.isManual(a),'a new arbiter is in manual control')
    check(not ControlArbiter.canAct(a,'auto_combat'),'no source may act before a grant')
    local ok,code=ControlArbiter.grant(a,'auto_combat','player started auto')
    check(ok and code=='granted' and ControlArbiter.canAct(a,'auto_combat'),'grant hands over control')
    check(not ControlArbiter.grant(a,'remote'),'another source cannot take a held lease')
    local moved,previous=ControlArbiter.manualInput(a,'player moved')
    check(moved and previous=='auto_combat','manual input revokes the lease')
    check(ControlArbiter.isManual(a) and not ControlArbiter.canAct(a,'auto_combat'),
        'after manual input the plugin cannot act')
    check(not ControlArbiter.revoke(a,'auto_combat'),'a non-owner cannot revoke')
end

-- 2. PolicyStore -------------------------------------------------------------
do
    local s=PolicyStore.new()
    local p=policy()
    local result,err=PolicyStore.setDraft(s,p,nil)
    check(result and result.draft_hash,'a valid policy becomes the draft')
    check(not PolicyStore.approve(s,'deadbeef'),'approve rejects a stale expected_hash')
    local approved=PolicyStore.approve(s,result.draft_hash)
    check(approved and approved.approved_hash==result.draft_hash,'approve certifies the draft')
    check(not PolicyStore.activate(s,'deadbeef'),'activate rejects a stale approved hash')
    local running=PolicyStore.activate(s,approved.approved_hash)
    check(running and running.running_hash==approved.approved_hash,'activate promotes the approved policy')
    local hashes=PolicyStore.hashes(s)
    check(hashes.draft==hashes.approved and hashes.approved==hashes.running,'all three versions agree')
    check(not PolicyStore.setDraft(s,policy(),'deadbeef'),'a conflicting draft write is refused')
    local bad=policy(); bad.rules[1]['then'].talent='T_NOT_ALLOWED'
    local invalid=PolicyStore.setDraft(s,bad,nil)
    check(invalid==nil,'an invalid policy is never stored')
end
do
    local s=PolicyStore.new()
    check(not PolicyStore.approve(s),'cannot approve without a draft')
    check(not PolicyStore.activate(s),'cannot activate without an approved policy')
end

-- 3. AutoCombat state machine ------------------------------------------------
local function makeHost()
    local h={phase_='ready',oid=1,requests={},notifications={},
        snap={hp_pct=80,enemy_count=1,resource_pct=function() return 100 end},
        enemies={},responses={}}
    h.phase=function() return h.phase_ end
    h.opportunity_id=function() return h.oid end
    h.snapshot=function(selector) h.snap.binding_selector=selector; return h.snap end
    h.enemy_ids=function() return h.enemies end
    h.notify=function(ev) h.notifications[#h.notifications+1]=ev end
    h.request=function(attempt)
        h.requests[#h.requests+1]=attempt
        local next_response=table.remove(h.responses,1)
        return next_response or {status='ok'}
    end
    return h
end

do
    local host=makeHost(); host.phase_='settling'
    local c=AutoCombat.new(policy(),host)
    local started=c:start()
    check(started.state=='awaiting_ready','start while settling waits for ready')
    host.phase_='ready'
    local step=c:onOpportunity()
    check(step.action=='acted' and c.state=='running','a later ready boundary begins the run')
end

do
    local host=makeHost()
    local c=AutoCombat.new(policy(),host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='acted' and #host.requests==1,'a ready start acts immediately')
    check(host.requests[1].rule=='beam','the highest-priority matching rule acts')
    local stale=c.generation
    c:pause('test')
    check(c:isStale(stale),'a decision from before a pause is stale')
end

do
    -- Rejected with no energy: not retried as-is, another rule is tried.
    local host=makeHost()
    host.responses={{status='rejected',energy_spent=false}}
    local c=AutoCombat.new(policy(),host)
    c:start(); local step=c:onOpportunity()
    check(#host.requests==2 and host.requests[1].rule=='beam' and host.requests[2].rule=='attack',
        'a denied rule is skipped and another rule is tried')
    check(step.action=='acted','the second rule can complete the opportunity')
end

do
    -- R-1: a settled reject that produced no native action does not consume the
    -- action budget, so the fall-through runs in the same opportunity even at
    -- max_actions_per_tick=1 (the schema-valid and assistant-import default).
    local host=makeHost()
    host.responses={{status='rejected',energy_spent=false}}
    local c=AutoCombat.new(policy({limits={max_actions_per_tick=1}}),host)
    c:start(); local step=c:onOpportunity()
    check(#host.requests==2 and host.requests[1].rule=='beam' and host.requests[2].rule=='attack',
        'a settled no-energy reject does not consume the budget (R-1)')
    check(step.action=='acted' and c.attempts==1,
        'the limit-1 opportunity falls through and completes one action (R-1)')
end

do
    -- The budget still bounds completed native actions per opportunity: with a
    -- repeated opportunity id the limit-1 budget pauses after one charged
    -- action, and the reason is honest (the cause is a completed action, never
    -- a refusal).
    local host=makeHost()
    local c=AutoCombat.new(policy({limits={max_actions_per_tick=1}}),host)
    c:start()
    check(c:onOpportunity().action=='acted' and c.attempts==1,'a completed action consumes the budget')
    local step=c:onOpportunity()
    check(step.action=='paused' and step.reason=='budget_exhausted',
        'the limit-1 budget pauses after the completed action (budget_exhausted stays honest)')
    check(#host.requests==1,'the exhausted budget does not submit again')
end

do
    -- Budget does not reset on a repeated opportunity id, but does on a new one.
    local host=makeHost()
    local c=AutoCombat.new(policy({limits={max_actions_per_tick=2}}),host)
    c:start()
    check(c:onOpportunity().action=='acted','the first opportunity acts')
    check(c:onOpportunity().action=='acted','a repeated opportunity id keeps spending its budget')
    check(c.attempts==2,'both attempts count in the same opportunity')
    host.oid=2
    local third=c:onOpportunity()
    check(third.action=='acted' and c.attempts==1,'a new action opportunity resets the budget')
end

do
    -- AC-01: resume must refuse while native work remains.
    local host=makeHost(); host.responses={{status='native_pending'}}
    local c=AutoCombat.new(policy(),host)
    c:start(); c:onOpportunity()
    host.phase_='native_pending'
    local refused=c:resume()
    check(refused.ok==false and refused.code=='native_pending','resume refuses a live native body')
    host.phase_='ready'
    local resumed=c:resume()
    check(resumed.ok==true and c.state=='running','resume proceeds once the native body settled')
end

do
    -- AC-05: unknown hp with a configured threshold pauses before any layer.
    local host=makeHost(); host.snap={hp_pct=nil,enemy_count=1}
    local c=AutoCombat.new(policy(),host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='paused' and step.reason=='unknown_safety' and step.detail=='hp_pct',
        'unknown hp is an executor-level unknown-safety pause')
    check(#host.requests==0,'no rule is evaluated with unknown hp')
end

do
    -- AC-04: no visible enemy ends the run before sustain maintenance.
    local host=makeHost(); host.snap={hp_pct=80,enemy_count=0}
    host.sustain_on=function() return false end
    host.talent_known=function() return true end
    local p=policy({sustains={{talent='T_CHANT_OF_FORTRESS',priority=20}}})
    local c=AutoCombat.new(p,host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='stopped' and step.reason=='no_visible_enemies' and #host.requests==0,
        'no visible enemy ends before a sustain can activate')
end

do
    -- AC-04: in the critical layer a sustain is never attempted; the emergency
    -- self-preservation rule runs instead.
    local host=makeHost(); host.snap={hp_pct=10,enemy_count=1}
    host.sustain_on=function() return false end
    host.talent_known=function() return true end
    local p=policy({safety={min_hp_pct=35,flee_below_hp_pct=5},sustains={{talent='T_CHANT_OF_FORTRESS',priority=20}},rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}}}})
    local c=AutoCombat.new(p,host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='acted' and step.rule=='heal' and host.requests[1].action=='use_talent',
        'the critical layer skips the sustain and runs the emergency rule')
end

do
    -- AC-06: instant cap is per opportunity and not reset by display frames.
    local host=makeHost(); host.snap={hp_pct=80,enemy_count=1}
    host.responses={{status='ok',instant=true,energy_spent=false},{status='ok',instant=true,energy_spent=false}}
    local p=policy({limits={max_actions_per_tick=4,max_instant_per_tick=1},rules={
        {id='instant',priority=10,when={always={}},
            ['then']={action='use_talent',talent='T_TWILIGHT',target='self'}}}})
    local c=AutoCombat.new(p,host)
    c:start()
    check(c:onOpportunity().action=='acted','an instant action runs once')
    check(c.instant_attempts==1,'the instant outcome is counted')
    host.oid=2
    check(c:onOpportunity().action=='acted','a new opportunity resets the instant budget')
    check(c.instant_attempts==1,'the reset budget allows another instant')
    local capped=c:onOpportunity()
    check(capped.action=='paused' and capped.reason=='instant_budget_exhausted',
        'the instant cap pauses before another instant submission in the same opportunity')
end

do
    -- D6: min_resource_pct gates a sustain; unknown resource state is skipped.
    local function sustainHost(pct)
        local host=makeHost(); host.snap={hp_pct=80,enemy_count=1}
        host.sustain_on=function() return false end
        host.talent_known=function() return true end
        host.resource_pct=function() return pct end
        return host
    end
    local p=policy({sustains={{talent='T_CHANT_OF_FORTRESS',priority=20,min_resource_pct=50}}})
    local low=AutoCombat.new(p,sustainHost(10)); low:start()
    check(low:sustainStep()==nil,'a low resource blocks the sustain')
    local high=AutoCombat.new(p,sustainHost(80)); high:start()
    check(high:onOpportunity().rule=='sustain:T_CHANT_OF_FORTRESS','a sufficient resource allows the sustain')
    local unknown=AutoCombat.new(p,sustainHost(nil)); unknown:start()
    check(unknown:sustainStep()==nil,'unknown resource state is not activated')
end

do
    -- D6: flee_below_hp_pct is a distinct pause reason (no auto-retreat).
    local host=makeHost(); host.snap={hp_pct=10,enemy_count=1}
    local p=policy({safety={min_hp_pct=35,flee_below_hp_pct=15}})
    local c=AutoCombat.new(p,host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='paused' and step.reason=='flee_below_hp_pct',
        'flee_below_hp_pct pauses with its own reason')
end

do
    -- Log dedupe: re-issuing the same pause is not a new transition and must
    -- not notify/log again (the old resume-at-low-HP loop appended one event
    -- per call and evicted the bounded decision log).
    local host=makeHost(); host.snap={hp_pct=10,enemy_count=1}
    local p=policy({safety={min_hp_pct=35,flee_below_hp_pct=15}})
    local c=AutoCombat.new(p,host)
    c:start()
    local first=c:onOpportunity()
    local notifications=#host.notifications
    local again=c:pause('flee_below_hp_pct')
    check(again.deduplicated==true and #host.notifications==notifications,
        'a repeated identical pause does not notify again')
    check(again.generation==first.generation,'a repeated pause does not advance the generation')
end

do
    -- Stop dedupe: an already-stopped run does not advance the generation.
    local host=makeHost(); local c=AutoCombat.new(policy(),host); c:start()
    c:stop('one')
    local generation=c.generation
    local again=c:stop('one')
    check(again.deduplicated==true and c.generation==generation,
        'a repeated identical stop is deduplicated')
end

do
    -- Code coverage for the execution-boundary pause reasons that live combat
    -- did not hit in round 3 (declared expected reasons).
    local host=makeHost(); host.responses={{status='rejected',energy_spent=true}}
    local c=AutoCombat.new(policy({limits={max_actions_per_tick=1}}),host); c:start()
    local denied=c:onOpportunity()
    check(denied.action=='paused' and denied.reason=='action_denied',
        'a rejection that spent energy pauses action_denied')
    local host2=makeHost(); host2.responses={{status='uncertain'}}
    local c2=AutoCombat.new(policy({limits={max_actions_per_tick=1}}),host2); c2:start()
    local uncertain=c2:onOpportunity()
    check(uncertain.action=='paused' and uncertain.reason=='action_uncertain',
        'an uncertain outcome pauses action_uncertain')
    local host3=makeHost()
    local c3=AutoCombat.new(policy(),host3); c3:start()
    host3.phase_='waiting_player'
    local interaction=c3:onOpportunity()
    check(interaction.action=='paused' and interaction.reason=='player_interaction',
        'a waiting_player phase pauses player_interaction')
end

do
    -- AC-03/D1/D2: the controller consults the production guard before
    -- submitting. R-1: a guard rejection never reaches the native executor and
    -- produces no native action, so it does not consume the budget; the next
    -- candidate is submitted in the same opportunity.
    local host=makeHost(); host.snap={hp_pct=80,enemy_count=1}
    local seen=false
    host.guard=function(attempt) seen=true
        if attempt.rule=='beam' then return {action='reject',reason='selffire_risk'} end end
    local c=AutoCombat.new(policy({limits={max_actions_per_tick=1}}),host)
    c:start()
    local step=c:onOpportunity()
    check(seen,'the guard runs')
    check(step.action=='acted' and #host.requests==1 and c.attempts==1,
        'a guard rejection does not consume the limit-1 budget (R-1)')
end

do
    -- AC-03/D2: a guard pause returns the guard reason.
    local host=makeHost(); host.snap={hp_pct=80,enemy_count=1}
    host.guard=function() return {action='pause',reason='selffire_risk'} end
    local c=AutoCombat.new(policy(),host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='paused' and step.reason=='selffire_risk','a guard pause surfaces its reason')
    check(#host.requests==0,'a guard rejection never reaches the executor')
end

do
    -- native_pending is an internal wait, never a failure, and never resubmits.
    local host=makeHost()
    host.responses={{status='native_pending'}}
    local c=AutoCombat.new(policy(),host)
    c:start()
    local first=c:onOpportunity()
    check(first.action=='wait_native' and c.state=='waiting_native','native_pending enters an internal wait')
    host.phase_='native_pending'
    local second=c:onOpportunity()
    check(second.action=='wait_native' and #host.requests==1,'the wait never resubmits the action')
    host.phase_='ready'
    local third=c:onOpportunity()
    check(third.action=='acted' and #host.requests==2,'after settling the run continues')
end

do
    -- A native-activity rule (rest) carries its bounded max_turns and, while the
    -- activity is live, is a native_pending wait that is never resubmitted.
    local host=makeHost(); host.responses={{status='native_pending'}}
    local p=policy({limits={max_actions_per_tick=1},rules={
        {id='camp',priority=50,when={always={}},['then']={action='rest',max_turns=3}}}})
    local c=AutoCombat.new(p,host)
    c:start()
    local first=c:onOpportunity()
    check(first.action=='wait_native' and c.state=='waiting_native',
        'a rest rule enters an internal wait while the activity runs')
    check(host.requests[1].action=='rest' and host.requests[1].max_turns==3,
        'the rest attempt carries the rule max_turns')
    host.phase_='settling'
    check(c:onOpportunity().action=='wait_native' and #host.requests==1,
        'the live activity is never resubmitted')
    host.phase_='ready'
    c:onOpportunity()
    check(#host.requests==2,'the controller resumes after the activity settles')
end

do
    -- Target binding: the winning rule's selector must bind the same target the
    -- condition was checked against, or the rule is denied.
    local function bindingHost(bindings)
        local h=makeHost()
        h.snapshot=function(selector)
            local b=bindings[selector] or {}
            return {hp_pct=80,enemy_count=1,binding_selector=selector,enemy_hp_pct=b.hp_pct,bound_target=b.id}
        end
        return h
    end
    local p=policy({targeting={default='nearest_hostile'},limits={max_actions_per_tick=1},rules={
        {id='finish',priority=10,when={enemy_hp_pct={lt=30}},
            ['then']={action='use_talent',talent='T_SEARING_LIGHT',target='lowest_hp_hostile'}}}})
    local host=bindingHost({nearest_hostile={id='near',hp_pct=20},lowest_hp_hostile={id='low',hp_pct=90}})
    local c=AutoCombat.new(p,host); c:start()
    local step=c:onOpportunity()
    check(step.action=='stopped' and step.reason=='no_available_action' and #host.requests==0,
        'a target-specific condition is evaluated against the action selector, not fired')
    local seen=false
    for _,row in ipairs(step.results or {}) do
        if row.rule=='finish' and row.result=='false' then seen=true end
    end
    check(seen,'the mismatched rule is recorded as false in the decision trace')
    host=bindingHost({nearest_hostile={id='near',hp_pct=20},lowest_hp_hostile={id='low',hp_pct=10}})
    c=AutoCombat.new(p,host); c:start()
    step=c:onOpportunity()
    check(step.action=='acted' and step.bound_target=='low' and host.requests[1].bound_target=='low',
        'the executed action uses the same bound target as the condition')
end

do
    -- Strict resume: confirm the current enemy set, then pause on a new enemy.
    local host=makeHost(); host.enemies={'a'}
    local c=AutoCombat.new(policy(),host,{strict=true})
    c:start()
    check(c:onOpportunity().action=='acted','a known enemy set does not pause')
    host.enemies={'a','b'}
    local paused=c:onOpportunity()
    check(paused.action=='paused' and paused.reason=='new_enemy','a new hostile pauses in strict mode')
    c:resume()
    check(c:onOpportunity().action=='acted','resume confirms the current enemy set')
    host.enemies={'a','b','c'}
    check(c:onOpportunity().reason=='new_enemy','a later new hostile still pauses after resume')
end

-- D-3: `on_new_enemy='continue'` updates the visible target set without parking
-- the run (a group fight must not freeze on every wandering enemy).
do
    local host=makeHost(); host.enemies={'a'}
    local p=policy({mode={on_new_enemy='continue'}})
    local c=AutoCombat.new(p,host,{strict=true})
    c:start()
    check(c:onOpportunity().action=='acted','the initial visible set acts')
    host.enemies={'a','b'}
    local step=c:onOpportunity()
    check(step.action=='acted','a new hostile does not pause under on_new_enemy=continue (D-3)')
    check(c.known_enemies['b']==true,'the visible target set is refreshed in place')
    -- The legacy boolean is coherent with the explicit mode.
    local legacy=policy({safety={min_hp_pct=35,flee_below_hp_pct=25,pause_on_new_enemy=false}})
    local host2=makeHost(); host2.enemies={'a'}
    local c2=AutoCombat.new(legacy,host2,{strict=true})
    c2:start(); c2:onOpportunity()
    host2.enemies={'a','b'}
    check(c2:onOpportunity().action=='acted',
        'safety.pause_on_new_enemy=false maps to continue (D-3)')
end

-- D-1 (P1, round anor-reg-01 live regression): an emergency action natively
-- refused on cooldown must not park the run. The run keeps acting, the
-- cooldown is observed to recover, and the emergency action is used again.
do
    local host=makeHost()
    host.snap={hp_pct=30,enemy_count=1}
    local cooldown=3
    local heal_attempts=0
    host.request=function(attempt)
        host.requests[#host.requests+1]=attempt
        if attempt.rule=='heal' then
            heal_attempts=heal_attempts+1
            if cooldown>0 then
                return {status='rejected',code='native_rejected',energy_spent=false,
                    missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=cooldown,required=0}},
                    native_message='Healing Light is still on cooldown for '..cooldown..' turns.'}
            end
            return {status='ok'}
        end
        -- The fall-through action spends the turn: time passes, so the native
        -- cooldown decays (exactly what a pause would prevent).
        cooldown=math.max(0,cooldown-1)
        return {status='ok'}
    end
    local p=policy({mode={on_low_hp='emergency_only'},limits={max_actions_per_tick=2},rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
        {id='attack',priority=40,when={always={}},
            ['then']={action='attack',target='nearest_hostile'}}}})
    local c=AutoCombat.new(p,host)
    c:start()
    local acted,parked,usedHeal=0,0,false
    for _=1,6 do
        local step=c:onOpportunity()
        if step.action=='acted' then
            acted=acted+1
            if step.rule=='heal' then usedHeal=true end
        elseif step.action=='paused' then parked=parked+1 end
        host.oid=host.oid+1
    end
    check(acted>=3,'the run keeps acting while the emergency action is on cooldown (D-1)')
    check(parked==0,'a refused emergency action never parks while a fallback exists (D-1)')
    check(usedHeal,'after the cooldown recovers the emergency action is used again (D-1)')
    check(heal_attempts>=2,'the emergency action is retried once the cooldown recovered (D-1)')
end

do
    -- R-1 (P1 regression): at max_actions_per_tick=1 a refused emergency action
    -- must fall through in the same opportunity: the fallback acts, time passes,
    -- the cooldown decays and the emergency action is used again. The old
    -- charged-per-attempt contract consumed the only attempt on the refusal and
    -- paused budget_exhausted with the lease held — the same livelock under a
    -- different reason.
    local cooldown=3
    local host=makeHost()
    host.snap={hp_pct=30,enemy_count=1}
    host.request=function(attempt)
        host.requests[#host.requests+1]=attempt
        if attempt.rule=='heal' then
            if cooldown>0 then
                return {status='rejected',code='native_rejected',energy_spent=false,
                    missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=cooldown,required=0}}}
            end
        end
        -- Every charged submission spends the turn: time passes, so the native
        -- cooldown decays (exactly what a frozen pause would prevent).
        cooldown=math.max(0,cooldown-1)
        return {status='ok',energy_spent=true}
    end
    local p=policy({mode={on_low_hp='emergency_only'},limits={max_actions_per_tick=1},rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
        {id='attack',priority=40,when={always={}},
            ['then']={action='attack',target='nearest_hostile'}}}})
    local c=AutoCombat.new(p,host)
    c:start()
    local acted,parked,usedHeal=0,0,false
    for _=1,6 do
        local step=c:onOpportunity()
        if step.action=='acted' then
            acted=acted+1
            if step.rule=='heal' then usedHeal=true end
        elseif step.action=='paused' then parked=parked+1 end
        host.oid=host.oid+1
    end
    check(acted>=3,'the limit-1 run keeps acting while the emergency action is on cooldown (R-1)')
    check(parked==0,'a refused emergency action never parks the limit-1 run (R-1)')
    check(usedHeal,'after the cooldown recovers the emergency action is used again (R-1)')
end

do
    -- R-1: when genuinely nothing is applicable after an emergency refusal, the
    -- run stops with the typed refusal (`action_denied`) and releases control —
    -- it must not pause with the lease held over a frozen world.
    local host=makeHost()
    host.snap={hp_pct=30,enemy_count=1}
    host.request=function(attempt)
        host.requests[#host.requests+1]=attempt
        return {status='rejected',code='native_rejected',energy_spent=false}
    end
    local p=policy({mode={on_low_hp='emergency_only'},limits={max_actions_per_tick=1},rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
        {id='unreachable',priority=40,when={enemy_count={ge=99}},
            ['then']={action='attack',target='nearest_hostile'}}}})
    local c=AutoCombat.new(p,host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='stopped' and step.reason=='action_denied' and step.rule=='heal',
        'a refused emergency action with no applicable fallback stops with the typed refusal (R-1)')
    check(c.state=='stopped' and c.reason=='action_denied',
        'the refusal terminal is a stop, not a held-lease pause (R-1)')
    check(#host.requests==1,'the refusal terminal submits exactly once')
    local sawRefusal=false
    for _,row in ipairs(step.results or {}) do
        if row.rule=='heal' and row.result=='denied' then sawRefusal=true end
    end
    check(sawRefusal,'the refusal is recorded in the decision trace')
end

do
    -- D-2: a native refusal's structured detail (cooldown `missing`,
    -- `native_message`, `hint`) reaches the notify callback (policy log), the
    -- same detail the command path already returns.
    local host=makeHost()
    host.snap={hp_pct=30,enemy_count=1}
    host.request=function(attempt)
        host.requests[#host.requests+1]=attempt
        return {status='rejected',code='native_rejected',energy_spent=false,
            missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=7,required=0}},
            hint='talent on cooldown; wait for the listed turns before retrying',
            native_message='Healing Light is still on cooldown for 7 turns.'}
    end
    local p=policy({mode={on_low_hp='emergency_only'},limits={max_actions_per_tick=1},rules={
        {id='heal',priority=100,emergency=true,when={always={}},
            ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}}}})
    local c=AutoCombat.new(p,host)
    local notified
    c.notify=function(event) if event.kind=='denied' then notified=event end end
    c:start()
    c:onOpportunity()
    check(notified and notified.rule=='heal' and notified.reason=='native_rejected',
        'the auto denied event is emitted (D-2)')
    check(notified.missing and notified.missing[1] and notified.missing[1].kind=='cooldown'
        and notified.missing[1].remaining==7 and notified.missing[1].talent=='T_HEALING_LIGHT',
        'the auto denied event carries the structured cooldown missing (D-2)')
    check(notified.native_message=='Healing Light is still on cooldown for 7 turns.',
        'the auto denied event carries the native message (D-2)')
    check(type(notified.hint)=='string','the auto denied event carries the hint (D-2)')
end

do
    -- Declared sustains are enabled before offensive rules; unknown desired
    -- state and unknown talents are skipped, not paused.
    local host=makeHost()
    host.sustain_on=function(id)
        if id=='T_CHANT_OF_FORTRESS' then return nil end
        return false
    end
    host.talent_known=function(id) return id~='T_CHANT_OF_FORTRESS' end
    local p=policy({sustains={{talent='T_CHANT_OF_FORTRESS',priority=20},
        {talent='T_HYMN_OF_SHADOWS',priority=10}}})
    local c=AutoCombat.new(p,host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='acted' and step.rule=='sustain:T_HYMN_OF_SHADOWS',
        'an off, known sustain is enabled before a rule')
    check(host.requests[1].action=='set_sustain' and host.requests[1].talent=='T_HYMN_OF_SHADOWS',
        'the sustain uses the native set_sustain action')
    host.sustain_on=function() return true end
    local settled=c:onOpportunity()
    check(settled.action=='acted' and settled.rule=='beam','once sustains are on the rule fires')
end

do
    -- A sustain attempt counts against the per-opportunity budget and is not
    -- retried while the desired state is still off.
    local host=makeHost()
    host.sustain_on=function() return false end
    host.talent_known=function() return true end
    local p=policy({sustains={{talent='T_HYMN_OF_SHADOWS',priority=10}},
        limits={max_actions_per_tick=1}})
    local c=AutoCombat.new(p,host)
    c:start()
    local first=c:onOpportunity()
    check(first.action=='acted' and #host.requests==1,'the first sustain attempt runs once')
    c:onOpportunity()
    check(#host.requests==1,'the attempt budget stops sustain spam')
end

do
    -- No visible enemy ends the run instead of holding the lease forever.
    local host=makeHost()
    host.snap={hp_pct=80,enemy_count=0}
    local c=AutoCombat.new(policy(),host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='stopped' and step.reason=='no_visible_enemies' and c.state=='stopped',
        'no visible enemy stops the run')
end

do
    -- A successful action increments the cumulative action total.
    local host=makeHost()
    local c=AutoCombat.new(policy(),host)
    c:start()
    c:onOpportunity()
    check(c:status().actions==1,'a successful action counts in the cumulative total')
end

-- §10 / §5.3: rejections, bounded recent decisions and the sustain failure cap.
do
    local host=makeHost()
    host.responses={{status='rejected',energy_spent=false},{status='rejected',energy_spent=false}}
    local c=AutoCombat.new(policy(),host)
    c:start(); c:onOpportunity()
    check(#c.rejections==2 and c.rejections[1].rule=='beam' and c.rejections[1].reason=='native_rejected'
        and c.rejections[2].rule=='attack','every denied rule is recorded with a reason')
    local recent=c:recentDecisions(1)
    check(#recent==1,'recentDecisions honours the limit')
    local sawDenied=false
    for _,entry in ipairs(c.recent) do if entry.kind=='denied' then sawDenied=true end end
    check(sawDenied,'recent decisions include the denials')
end
do
    local host=makeHost()
    host.sustain_on=function() return false end
    host.talent_known=function() return true end
    host.request=function(attempt)
        host.requests[#host.requests+1]=attempt
        if attempt.action=='set_sustain' then return {status='rejected',energy_spent=false} end
        return {status='ok',energy_spent=true}
    end
    local p=policy({limits={max_actions_per_tick=4},
        sustains={{talent='T_CHANT_OF_FORTRESS',priority=20}}})
    local c=AutoCombat.new(p,host)
    c:start()
    for _=1,AutoCombat.SUSTAIN_FAILURE_CAP do
        host.oid=(host.oid or 1)+1
        c:onOpportunity()
    end
    check(c.sustain_disabled['T_CHANT_OF_FORTRESS'],'a repeatedly rejected sustain is disabled for the run')
    check(c.sustain_failures['T_CHANT_OF_FORTRESS']>=AutoCombat.SUSTAIN_FAILURE_CAP,
        'the sustain failure count reaches the cap')
    local attempts=0
    for _,entry in ipairs(host.requests) do if entry.action=='set_sustain' then attempts=attempts+1 end end
    check(attempts==AutoCombat.SUSTAIN_FAILURE_CAP,'a disabled sustain is not attempted again')
end

-- P0/F4: a bounded native abort is a typed controller event in the decision ring
-- and (through notify) the policy log, carrying the action, talent, target and
-- elapsed ticks/frames. It never mutates the native game.
do
    local host=makeHost()
    local c=AutoCombat.new(policy(),host)
    c:start()
    local entry=c:nativeAborted({code='native_timeout',rule='beam',action='use_talent',
        talent='T_MOONLIGHT_RAY',target='e1',elapsed_ticks=12,elapsed_frames=40})
    check(entry.kind=='native_aborted' and entry.reason=='native_timeout',
        'the abort is recorded as a typed native_aborted decision')
    check(entry.action=='use_talent' and entry.talent=='T_MOONLIGHT_RAY' and entry.target=='e1'
        and entry.elapsed_ticks==12 and entry.elapsed_frames==40,
        'the abort event carries the action, talent, target and elapsed ticks/frames')
    local notified
    for _,event in ipairs(host.notifications) do
        if event.kind=='native_aborted' then notified=event end
    end
    check(notified and notified.reason=='native_timeout' and notified.elapsed_frames==40,
        'the abort reaches the notify callback (policy log)')
    local recent=false
    for _,event in ipairs(c.recent) do if event.kind=='native_aborted' then recent=true end end
    check(recent,'the abort is retained in the bounded decision ring')
    local denied=false
    for _,rejection in ipairs(c.rejections) do
        if rejection.rule=='beam' and rejection.reason=='native_timeout' then denied=true end
    end
    check(denied,'the aborted rule is recorded in the opportunity rejections')
end

-- S2 rev3/§6.2: a deviation riding on a `native_pending` result pauses BEFORE the
-- controller's native_pending branch (it never enters waiting_native), and a
-- settled-time deviation delivered by nativeDeviated does the same.
do
    local requests=0
    local host=makeHost()
    host.request=function(attempt)
        host.requests[#host.requests+1]=attempt
        requests=requests+1
        return {status='native_pending',code='native_pending',energy_spent=true,
            handed_back=true,
            sequence_deviation={reason='unexpected_target_request',
                expected={index=1,request='actor'},observed={index=1,request='grid'},
                handed_back=true,skippable=false}}
    end
    local c=AutoCombat.new(policy(),host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='paused' and step.reason=='unexpected_target_request',
        'a native_pending carrying a deviation pauses instead of entering waiting_native')
    check(step.handed_back==true and c.state=='paused' and c.reason=='unexpected_target_request',
        'the pause carries the handback evidence and the typed reason')
    check(requests==1 and c.attempts==0,
        'the pending deviation is never resubmitted and consumes no action budget')
end
do
    local host=makeHost()
    local c=AutoCombat.new(policy(),host)
    c:start()
    local entry=c:nativeDeviated({reason='movement_request_kind_unknown',handed_back=true})
    check(entry.kind=='paused' and entry.reason=='movement_request_kind_unknown'
        and entry.handed_back==true,
        'nativeDeviated records the settle-time deviation as a paused handback event')
    local notified
    for _,event in ipairs(host.notifications) do
        if event.kind=='paused' and event.reason=='movement_request_kind_unknown' then notified=event end
    end
    check(notified,'the settle-time deviation reaches the notify callback (policy log)')
end

-- S2-FIX5: the synchronous deviation pause logs the typed deviation event
-- itself — WITH its rule and bounded detail — and never a second, detail-less
-- `paused` record (the live S2 playtest's paused `unexpected_target_request`
-- events carried neither).
do
    local host=makeHost()
    host.responses={{status='uncertain',code='unexpected_target_request',energy_spent=true,
        handed_back=true,
        sequence_deviation={reason='unexpected_target_request',
            expected={index=1,request='actor'},observed={index=1,request=nil},
            observed_shape='ball',handed_back=true,skippable=false}}}
    local c=AutoCombat.new(policy(),host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='paused' and step.reason=='unexpected_target_request',
        'a synchronous deviation still pauses with its typed reason')
    local logged={}
    for _,event in ipairs(host.notifications) do
        if event.kind=='paused' and event.reason=='unexpected_target_request' then
            logged[#logged+1]=event
        end
    end
    check(#logged==1 and logged[1].rule=='beam',
        'exactly one deviation pause event is logged and it carries its rule')
    check(logged[1].detail~=nil and logged[1].detail.expected~=nil
        and logged[1].detail.expected.index==1 and logged[1].detail.observed~=nil
        and logged[1].detail.skippable==false,
        'the logged deviation pause carries its bounded identifying detail')
    check(logged[1].handed_back==true,
        'the logged deviation pause carries the handback evidence')
end

-- S2-FIX5: an ordinary native rejection WITHOUT a deviation (a pre-prompt
-- cooldown refusal mapped through the production outcome) is never a
-- fabricated pause: no paused/unexpected_target_request event, the ordinary
-- native_rejected refusal is recorded instead.
do
    local host=makeHost()
    host.responses={
        {status='rejected',code='native_rejected',energy_spent=false,
            missing={{kind='cooldown',talent='T_PHASE_DOOR',remaining=11,required=0}},
            hint='talent on cooldown; wait for the listed turns before retrying'},
        {status='ok'},
    }
    local c=AutoCombat.new(policy(),host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='acted',
        'an ordinary native rejection denies its rule and falls through (no pause)')
    local denied
    for _,rejection in ipairs(c.rejections) do
        if rejection.rule=='beam' and rejection.reason=='native_rejected' then denied=true end
    end
    check(denied,'the pre-prompt refusal is recorded as an ordinary native_rejected denial')
    for _,event in ipairs(host.notifications) do
        check(not (event.kind=='paused' and event.reason=='unexpected_target_request'),
            'an ordinary native rejection never fabricates an unexpected_target_request pause')
    end
end
print('Auto-combat controller: '..checks..' checks passed')
