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
        'a rule whose bound target fails its own condition is denied, not fired')
    local denied=false
    for _,note in ipairs(host.notifications) do
        if note.kind=='denied' and note.rule=='finish' then denied=true end
    end
    check(denied,'a denied rule is recorded in the decision log')
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
print('Auto-combat controller: '..checks..' checks passed')
