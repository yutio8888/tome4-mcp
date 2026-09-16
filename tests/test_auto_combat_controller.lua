-- Contract tests for the P1a control/execution layer: ControlArbiter (control is
-- separate from certification), PolicyStore (draft/approved/running hashes), and
-- the AutoCombat state machine (start-when-ready, budget, native_pending,
-- pause/resume generations, strict resume).
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
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
    check(not ControlArbiter.grant(a,'mcp'),'another source cannot take a held lease')
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
    h.snapshot=function() return h.snap end
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
    -- Budget: all real attempts count; exhaustion pauses.
    local host=makeHost()
    host.responses={{status='rejected',energy_spent=false}}
    local c=AutoCombat.new(policy({limits={max_actions_per_tick=1}}),host)
    c:start(); local step=c:onOpportunity()
    check(step.action=='paused' and step.reason=='budget_exhausted',
        'the attempt budget pauses once exhausted')
    check(#host.requests==1,'the exhausted budget does not retry')
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

print('Auto-combat controller: '..checks..' checks passed')
