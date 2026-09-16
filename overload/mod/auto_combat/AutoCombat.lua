-- GPL-3.0-or-later. Auto-combat controller state machine (P1a).
--
-- The controller is a pure state machine over an injected host, so every
-- execution contract from the design doc is unit-testable without the engine:
--
--   host.phase()             -> 'ready' | 'settling' | 'native_pending' | 'waiting_player'
--   host.opportunity_id()    -> number that changes only on a new action opportunity
--   host.snapshot()          -> ctx table for PolicyEvaluator (hp_pct, resource_*, ...)
--   host.enemy_ids()         -> array of stable visible hostile ids (strict mode)
--   host.request(attempt)    -> {status='ok'|'rejected'|'native_pending'|'uncertain'|'error', energy_spent=bool}
--   host.notify(event)       -> nil (native UI / log)
--
-- Generation numbers guard deferred work: a step captured under generation N is
-- stale once the controller pauses/resumes/stops (generation > N).
local Evaluator=require 'mod.auto_combat.PolicyEvaluator'
local M={}
-- A rejected sustain is not retried forever: after this many rejected attempts
-- in one run the sustain is disabled for that run (design 5.3).
M.SUSTAIN_FAILURE_CAP=2
-- Bounded tail of recent decisions exposed to observers (design 10/11.2).
M.RECENT_LIMIT=8

function M.new(policy,host,options)
    options=options or {}
    return setmetatable({
        policy=policy,host=host,state='stopped',reason=nil,generation=0,
        attempts=0,instant_attempts=0,opportunity=0,opportunity_id=nil,actions=0,
        strict=options.strict~=false,denied={},known_enemies=nil,
        rejections={},recent={},sustain_failures={},sustain_disabled={},
        max_attempts=(policy.limits and policy.limits.max_actions_per_tick) or 1,
        notify=options.notify or (host and host.notify),
    },{__index=M})
end

function M:isStale(generation) return generation~=self.generation end

function M:newOpportunity()
    self.attempts=0; self.instant_attempts=0; self.denied={}; self.rejections={}
    self.opportunity=self.opportunity+1
end

function M:record(entry)
    entry.generation=entry.generation or self.generation
    self.recent[#self.recent+1]=entry
    if #self.recent>M.RECENT_LIMIT then table.remove(self.recent,1) end
end

-- Most recent decisions, newest first, bounded.
function M:recentDecisions(limit)
    limit=limit or M.RECENT_LIMIT
    local out={}
    for index=#self.recent,1,-1 do
        if #out>=limit then break end
        out[#out+1]=self.recent[index]
    end
    return out
end

function M:refreshOpportunity()
    if not (self.host and self.host.opportunity_id) then return end
    local oid=self.host.opportunity_id()
    if oid~=nil and oid~=self.opportunity_id then
        self.opportunity_id=oid
        self:newOpportunity()
    end
end

-- Strict mode pauses once for a newly visible hostile set. On start/resume the
-- current set is confirmed, so the same enemies do not re-trigger; later new
-- enemies still do.
function M:checkEnemies()
    if not self.strict or not (self.host and self.host.enemy_ids) then return nil end
    local ids=self.host.enemy_ids()
    if type(ids)~='table' then return nil end
    if not self.known_enemies then
        self.known_enemies={}
        for _,id in ipairs(ids) do self.known_enemies[id]=true end
        return nil
    end
    for _,id in ipairs(ids) do
        if not self.known_enemies[id] then
            for _,other in ipairs(ids) do self.known_enemies[other]=true end
            return 'new_enemy'
        end
    end
    return nil
end

function M:start()
    if self.state~='stopped' then return {ok=false,code='already_started',state=self.state} end
    self.generation=self.generation+1
    self.known_enemies=nil
    local phase=self.host and self.host.phase and self.host.phase() or 'ready'
    if phase=='ready' then
        self.state='running'; self.reason='started'
        self:newOpportunity()
        return {ok=true,state=self.state,generation=self.generation,action='schedule_pump'}
    end
    self.state='awaiting_ready'; self.reason='start_when_ready'
    return {ok=true,state=self.state,generation=self.generation,action='wait_for_ready',phase=phase}
end

function M:stop(reason)
    self.generation=self.generation+1
    self.state='stopped'; self.reason=reason or 'stopped'
    self.known_enemies=nil
    return {ok=true,state=self.state,generation=self.generation,action='release'}
end

function M:pause(reason)
    self.generation=self.generation+1
    self.state='paused'; self.reason=reason or 'paused'
    if self.notify then self.notify({kind='paused',reason=self.reason,generation=self.generation}) end
    return {action='paused',state=self.state,reason=self.reason,generation=self.generation}
end

function M:resume()
    if self.state~='paused' and self.state~='waiting_native' and self.state~='awaiting_ready' then
        return {ok=false,code='not_paused',state=self.state}
    end
    self.generation=self.generation+1
    self.known_enemies=nil  -- strict resume confirms the current enemy set
    self.state='running'; self.reason='resumed'
    self:newOpportunity()
    return {ok=true,state=self.state,generation=self.generation,action='schedule_pump'}
end

function M:findRule(id)
    for _,rule in ipairs(self.policy.rules or {}) do if rule.id==id then return rule end end
    return nil
end

function M:context(selector)
    if not (self.host and self.host.snapshot) then return {} end
    return self.host.snapshot(selector) or {}
end

-- Deny a rule/sustain for the rest of this action opportunity and record why.
function M:deny(id,reason)
    self.denied[id]=true
    reason=reason or 'denied'
    self.rejections[#self.rejections+1]={rule=id,reason=reason}
    self:record({kind='denied',rule=id,reason=reason})
    if self.notify then
        self.notify({kind='denied',reason=reason,rule=id,generation=self.generation})
    end
end

-- Return the highest-priority declared sustain that should be enabled now, or
-- nil. A sustain is only attempted when the host can tell us it is off and the
-- talent is not known to be missing.
function M:sustainStep()
    if not (self.host and type(self.host.sustain_on)=='function') then return nil end
    local limit=(self.policy.limits and self.policy.limits.max_actions_per_tick) or 1
    if self.attempts>=limit then return nil end
    local ordered={}
    for _,sustain in ipairs(self.policy.sustains or {}) do ordered[#ordered+1]=sustain end
    table.sort(ordered,function(a,b)
        local pa,pb=a.priority or 0,b.priority or 0
        if pa~=pb then return pa>pb end
        return tostring(a.talent)<tostring(b.talent)
    end)
    for _,sustain in ipairs(ordered) do
        if not self.denied[sustain.talent] and not self.sustain_disabled[sustain.talent] then
            local on=self.host.sustain_on(sustain.talent)
            if on==false then
                local known=self.host.talent_known and self.host.talent_known(sustain.talent)
                if known~=false then return sustain end
            end
        end
    end
    return nil
end

-- A rule's condition and its action must bind the same target. When the winning
-- rule uses a selector other than the context's, re-bind and re-check the
-- condition against the actually bound target before acting.
function M:rebind(ctx,decision)
    if not (self.host and self.host.snapshot) or ctx.binding_selector==nil
        or decision.target==nil or ctx.binding_selector==decision.target then
        return ctx
    end
    local rule=self:findRule(decision.rule)
    if not rule then return ctx end
    local rebound=self:context(decision.target)
    if rebound.binding_selector==decision.target
        and Evaluator.evalCondition(rule['when'],rebound)==Evaluator.TRUE then
        return rebound
    end
    return nil
end

function M:step()
    if self.state~='running' then return {action='noop',state=self.state} end
    local generation=self.generation
    local reason=self:checkEnemies()
    if reason then return self:pause(reason) end
    -- Declared sustains are maintained before spending the opportunity on an
    -- offensive rule. Unknown sustain state is skipped, not paused: it is an
    -- optimization input, not a safety boundary.
    local sustain=self:sustainStep()
    if sustain then
        self.attempts=self.attempts+1
        local outcome=(self.host and self.host.request and self.host.request({
            rule='sustain:'..sustain.talent,action='set_sustain',talent=sustain.talent,
            target='self',generation=generation})) or {}
        if outcome.status=='native_pending' then
            self.state='waiting_native'; self.reason='native_pending'
            return {action='wait_native',rule='sustain:'..sustain.talent,state=self.state,generation=generation}
        end
        if outcome.status=='ok' then
            self.actions=self.actions+1
            self:record({kind='acted',rule='sustain:'..sustain.talent,talent=sustain.talent})
            return {action='acted',rule='sustain:'..sustain.talent,talent=sustain.talent,
                outcome=outcome,rejections=self.rejections,state=self.state,generation=generation}
        end
        if outcome.status=='rejected' and outcome.energy_spent~=true then
            local count=(self.sustain_failures[sustain.talent] or 0)+1
            self.sustain_failures[sustain.talent]=count
            local capped=count>=M.SUSTAIN_FAILURE_CAP
            if capped then self.sustain_disabled[sustain.talent]=true end
            self:deny(sustain.talent,capped and 'sustain_failure_cap' or 'sustain_rejected')
        else
            return self:pause(outcome.status=='rejected' and 'action_denied' or 'action_uncertain')
        end
    end
    local default_selector=self.policy.targeting and self.policy.targeting.default
    for _=1,8 do
        local ctx=self:context(default_selector)
        ctx.attempts=self.attempts
        ctx.denied=self.denied
        local decision=Evaluator.evaluate(self.policy,ctx)
        if decision.decision=='pause' then
            self:record({kind='paused',reason=decision.reason,rule=decision.rule})
            local paused=self:pause(decision.reason)
            paused.results=decision.results; paused.rejections=self.rejections
            return paused
        end
        if decision.decision=='hold' then
            -- No idle waiting: when there is no executable rule (and no visible
            -- enemy left) the run ends and explains why, returning control.
            local holdreason=ctx.enemy_count==0 and 'no_visible_enemies' or 'no_available_action'
            self:record({kind='stopped',reason=holdreason})
            self:stop(holdreason)
            return {action='stopped',reason=holdreason,results=decision.results,
                rejections=self.rejections,state=self.state,generation=self.generation}
        end
        local bound=self:rebind(ctx,decision)
        if bound==nil then
            self:deny(decision.rule,'target_rebind_failed')
        else
            self.attempts=self.attempts+1
            local outcome=(self.host and self.host.request and self.host.request({
                rule=decision.rule,action=decision.action,talent=decision.talent,
                max_turns=decision.max_turns,
                target=decision.target,bound_target=bound.bound_target,generation=generation})) or {}
            if outcome.status=='native_pending' then
                self.state='waiting_native'; self.reason='native_pending'
                return {action='wait_native',rule=decision.rule,state=self.state,generation=generation}
            end
            if outcome.status=='ok' then
                self.actions=self.actions+1
                self:record({kind='acted',rule=decision.rule,talent=decision.talent,target=bound.bound_target})
                return {action='acted',rule=decision.rule,talent=decision.talent,bound_target=bound.bound_target,
                    results=decision.results,rejections=self.rejections,outcome=outcome,
                    state=self.state,generation=generation}
            end
            if outcome.status=='rejected' and outcome.energy_spent~=true then
                -- Explicitly rejected and no energy spent: do not retry as-is in
                -- this opportunity, but another rule may still be valid.
                self:deny(decision.rule,'native_rejected')
            else
                return self:pause(outcome.status=='rejected' and 'action_denied' or 'action_uncertain')
            end
        end
    end
    return self:pause('rule_loop_limit')
end

-- Called at each pumped action opportunity.
function M:onOpportunity()
    if self.state=='awaiting_ready' then
        if not (self.host and self.host.phase and self.host.phase()=='ready') then
            return {action='wait_for_ready',state=self.state,generation=self.generation}
        end
        self.generation=self.generation+1
        self.state='running'; self.reason='ready'
        self:newOpportunity()
    end
    if self.state=='waiting_native' then
        local phase=self.host and self.host.phase and self.host.phase() or 'ready'
        if phase~='ready' then
            return {action='wait_native',state=self.state,generation=self.generation}
        end
        self.state='running'; self.reason='native_settled'
        self:newOpportunity()  -- a settled native action is a fresh opportunity
    end
    if self.state~='running' then return {action='noop',state=self.state} end
    local phase=self.host and self.host.phase and self.host.phase() or 'ready'
    if phase=='settling' then return {action='wait',state=self.state,phase=phase} end
    if phase=='native_pending' then
        self.state='waiting_native'; self.reason='native_pending'
        return {action='wait_native',state=self.state,generation=self.generation}
    end
    if phase=='waiting_player' then return self:pause('player_interaction') end
    if phase~='ready' then return {action='wait',state=self.state,phase=phase} end
    self:refreshOpportunity()
    return self:step()
end

function M:status()
    local hashes=self.policy and require('mod.auto_combat.PolicySchema').hash(self.policy) or nil
    return {state=self.state,reason=self.reason,generation=self.generation,
        attempts=self.attempts,actions=self.actions,opportunity=self.opportunity,policy_hash=hashes}
end
return M
