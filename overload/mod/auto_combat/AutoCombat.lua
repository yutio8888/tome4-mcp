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
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
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
        rejected_landings={},
        max_attempts=(policy.limits and policy.limits.max_actions_per_tick) or 1,
        notify=options.notify or (host and host.notify),
    },{__index=M})
end

function M:isStale(generation) return generation~=self.generation end

function M:newOpportunity()
    self.attempts=0; self.instant_attempts=0; self.denied={}; self.rejections={}
    -- P2-1: the deterministic landing(s) a native call refused in this
    -- opportunity. Cleared per opportunity (the native collision result is
    -- geometry-bound to it); never carried across runs.
    self.rejected_landings={}
    self.opportunity=self.opportunity+1
end

-- The single landed coordinate of a deterministic movement plan, or nil when
-- the plan's landing is not a single coordinate (a bounded/random native choice
-- such as Rush or a teleport). Fallback selection never applies to those: they
-- must not be resubmitted as a different coordinate, so their behavior is
-- unchanged.
function M.landingKey(plan)
    if type(plan)~='table' then return nil end
    if plan.kind=='step' then
        if type(plan.x)=='number' and type(plan.y)=='number' then return plan.x..','..plan.y end
        return nil
    end
    if plan.kind=='grid' then
        local landing=plan.annotation and plan.annotation.landing
        if type(landing)=='table' and landing.kind=='deterministic'
            and type(plan.x)=='number' and type(plan.y)=='number' then
            return plan.x..','..plan.y
        end
        return nil
    end
    return nil
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
-- enemies still do. D-3: `on_new_enemy='continue'` keeps the target set current
-- and lets the policy keep acting (a group fight must not park on every
-- wandering enemy that enters sight); the pause is the conservative default.
function M:checkEnemies(mode)
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
            if mode=='continue' then return nil end
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
    reason=reason or 'stopped'
    -- A repeated stop of an already-stopped run is not a new transition: do not
    -- advance the generation or (through callers) log another boundary event.
    if self.state=='stopped' and self.reason==reason then
        return {ok=true,state=self.state,generation=self.generation,action='release',deduplicated=true}
    end
    self.generation=self.generation+1
    self.state='stopped'; self.reason=reason
    self.known_enemies=nil
    return {ok=true,state=self.state,generation=self.generation,action='release'}
end

function M:pause(reason)
    reason=reason or 'paused'
    -- Log/notify only on a real transition. Without this a caller that keeps
    -- re-issuing the same pause (for example the old resume-at-low-HP loop)
    -- appended one identical event per call and evicted the bounded log.
    if self.state=='paused' and self.reason==reason then
        return {action='paused',state=self.state,reason=self.reason,generation=self.generation,deduplicated=true}
    end
    self.generation=self.generation+1
    self.state='paused'; self.reason=reason
    if self.notify then self.notify({kind='paused',reason=self.reason,generation=self.generation}) end
    return {action='paused',state=self.state,reason=self.reason,generation=self.generation}
end

function M:resume()
    if self.state=='waiting_native' then
        -- AC-01: never force a live native body; only a settled boundary resumes.
        local phase=self.host and self.host.phase and self.host.phase()
        if phase~='ready' then return {ok=false,code='native_pending',state=self.state} end
    elseif self.state~='paused' and self.state~='awaiting_ready' then
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
-- Bounded, redaction-friendly projection of a risk/movement detail for the
-- decision trace and policy log (MFT-REV-07). Only scalar values and a small
-- set of known keys are carried; nested tables are shallow-copied with a cap.
local DETAIL_KEYS={'measurement','threshold','risk','unknown','provenance','phase','component',
    'landing','visible','remembered','known_passable','known_hazard','confidence','reasons',
    'selector','talent','scope','missing','native_message','hint','requests','friendlies','selffire','friendlyfire',
    'reason','expected','observed','index','dependency','exhausted','count','request','skippable'}
-- D-2: the structured `missing` array (for example the native cooldown entry
-- `{kind='cooldown',talent,remaining,required=0}`) is an array of small objects,
-- so the generic scalar-only table projection above would drop it. Project the
-- declared entry fields explicitly, bounded and type-guarded.
local MISSING_KINDS={cooldown=true,stat=true,level=true,talent=true,special=true}
local MISSING_KEYS={'kind','talent','remaining','required','stat','special','level'}
local function boundedMissing(value)
    if type(value)~='table' then return nil end
    local out={}
    for index=1,math.min(#value,8) do
        local entry=value[index]
        if type(entry)=='table' then
            local copy={}
            for _,key in ipairs(MISSING_KEYS) do
                local item=entry[key]
                if type(item)=='string' and #item<=128 then copy[key]=item
                elseif type(item)=='number' and item==item then copy[key]=item end
            end
            if copy.kind==nil or MISSING_KINDS[copy.kind] then out[index]=copy end
        end
    end
    if #out==0 then return nil end
    return out
end
M.boundedMissing=boundedMissing
local function boundedDetail(detail)
    if type(detail)~='table' then return nil end
    local out={}
    for _,key in ipairs(DETAIL_KEYS) do
        local value=detail[key]
        if value~=nil then
            if key=='missing' then
                local missing=boundedMissing(value)
                if missing then out[key]=missing end
            elseif type(value)=='string' then
                local limit=key=='native_message' and 512 or 256
                out[key]=#value<=limit and value or value:sub(1,limit)
            elseif type(value)=='table' then
                local copy={}
                local count=0
                for k,v in pairs(value) do
                    count=count+1
                    if count>16 then break end
                    if type(v)=='string' or type(v)=='number' or type(v)=='boolean' then copy[k]=v end
                end
                out[key]=copy
            elseif type(value)=='string' or type(value)=='number' or type(value)=='boolean' then
                out[key]=value
            end
        end
    end
    if next(out)==nil then return nil end
    return out
end
M.boundedDetail=boundedDetail

function M:deny(id,reason,detail)
    self.denied[id]=true
    reason=reason or 'denied'
    local entry={rule=id,reason=reason}
    if detail then entry.detail=boundedDetail(detail) end
    self.rejections[#self.rejections+1]=entry
    self:record({kind='denied',rule=id,reason=reason,detail=entry.detail})
    if self.notify then
        self.notify({kind='denied',reason=reason,rule=id,detail=entry.detail,
            -- D-2: the structured refusal detail (native cooldown `missing`,
            -- `native_message`, `hint`) is surfaced next to the deny so the
            -- client-visible policy log carries the same detail the command
            -- path already returns. `movement_retry` keeps its own `landing`.
            missing=entry.detail and entry.detail.missing or nil,
            native_message=entry.detail and entry.detail.native_message or nil,
            hint=entry.detail and entry.detail.hint or nil,
            landing=entry.detail and entry.detail.landing or nil,
            generation=self.generation})
    end
end

-- P2-1: a settled `native_rejected` for a deterministic movement landing is
-- not a dead end. The coordinate is recorded as excluded and the same
-- selector/anchor is re-planned so the already-declared deterministic
-- tie-break can choose the next acceptable alternative. The event is recorded
-- (and logged through notify) so the refusal stays visible; the rule is NOT
-- denied, so the controller keeps evaluating it within the per-tick budget.
function M:movementRetry(info)
    info=info or {}
    local entry={kind='movement_retry',reason=info.code or 'native_rejected',
        rule=info.rule,talent=info.talent,action=info.action,landing=info.landing,
        code=info.code,generation=info.generation or self.generation}
    self:record(entry)
    if self.notify then self.notify(entry) end
    return entry
end

-- F4/P0: an auto-slot native invocation the executor had to abort (it did not
-- settle within the executor's bound, so it would otherwise stay invisible in
-- `waiting_native`/`settling`) is a real controller event. It is recorded in the
-- bounded decision ring and (through notify) written to the policy log with the
-- action, talent, target and elapsed ticks/frames. This never mutates the native
-- game; the executor owns the cancellation.
function M:nativeAborted(info)
    info=info or {}
    local entry={kind='native_aborted',reason=info.code or 'native_timeout',
        rule=info.rule,action=info.action,talent=info.talent,target=info.target,
        elapsed_ticks=info.elapsed_ticks,elapsed_frames=info.elapsed_frames,
        generation=info.generation or self.generation}
    if info.rule then self.rejections[#self.rejections+1]={rule=info.rule,reason=entry.reason} end
    self:record(entry)
    if self.notify then self.notify(entry) end
    return entry
end

-- S2 rev3/§6.2 settle-time delivery (Path 2): an ordered-queue deviation that was
-- not delivered inside the submitting `step` (for example the native body
-- settled without player input, or the very first frame already ran past the
-- pump gate) is fed to the controller here. The typed reason drives the pause;
-- this is the same post-commit integrity pause the synchronous path uses, never
-- a strategy refusal. The Runtime pump owns the native side (the live handle is
-- cancelled at its bound); this function only records and pauses so the stall is
-- never invisible.
function M:nativeDeviated(deviation)
    deviation=deviation or {}
    local reason=deviation.reason or 'unexpected_target_request'
    local entry={kind='paused',reason=reason,detail=deviation,
        handed_back=deviation.handed_back==true or nil,
        generation=self.generation}
    self:record(entry)
    if self.notify then self.notify(entry) end
    -- Transition to paused without emitting a second `paused` notify (the typed
    -- entry above is the one recorded event). `nativeDeviation` then stops the
    -- run with the same reason.
    if self.state~='paused' or self.reason~=reason then
        self.generation=self.generation+1
        self.state='paused'; self.reason=reason
    end
    return entry
end

-- Return the highest-priority declared sustain that should be enabled now, or
-- nil. A sustain is only attempted when the host can tell us it is off and the
-- talent is not known to be missing.
function M:sustainStep()
    if not (self.host and type(self.host.sustain_on)=='function') then return nil end
    local limit=(self.policy.limits and self.policy.limits.max_actions_per_tick) or 1
    if self.attempts>=limit then return nil end
    if self:instantBudgetExhausted() then return nil end
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
                if known~=false and self:sustainResourceOk(sustain) then return sustain end
            end
        end
    end
    return nil
end

-- AC-06: per-opportunity instant budget. `instant_attempts` is reset only by a
-- new action opportunity, never by a display frame or snapshot refresh.
-- D6: `min_resource_pct` gates sustain activation. Unknown resource state is
-- not activated (fail-closed).
function M:sustainResourceOk(sustain)
    if not sustain.min_resource_pct then return true end
    local entry=Catalog.entry(sustain.talent)
    local resource=entry and entry.resource
    if not resource or not (self.host and type(self.host.resource_pct)=='function') then return false end
    local pct=self.host.resource_pct(resource)
    if type(pct)~='number' then return false end
    return pct>=sustain.min_resource_pct
end

function M:instantBudgetExhausted()
    local maxInstant=(self.policy.limits and self.policy.limits.max_instant_per_tick) or 3
    return self.instant_attempts>=maxInstant
end

function M:countInstant(outcome)
    if outcome and outcome.status=='ok' and outcome.instant==true then
        self.instant_attempts=self.instant_attempts+1
    end
end
function M:rebind(ctx,decision)
    -- MFT-REV-03: the action binding is authoritative even when the default
    -- snapshot selector was nil (for example an actor step selector with no
    -- `then.target`/`targeting.default`). The current binding is the snapshot
    -- selector, or the policy default when the snapshot omitted it. Re-bind and
    -- re-check when the decision target differs.
    local default_selector=self.policy.targeting and self.policy.targeting.default
    local current=ctx.binding_selector
    if current==nil then current=default_selector end
    if not (self.host and self.host.snapshot) or decision.target==nil
        or current==decision.target then
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
    local default_selector=self.policy.targeting and self.policy.targeting.default
    local pre=self:context(default_selector)
    -- v1.6 scheduling mode: the policy chooses no-enemy, low-HP and new-enemy
    -- behaviour. The executor no longer imposes a global flee pause or a fixed
    -- emergency layer; `emergency` is a scheduling label selected by
    -- `emergency_only`.
    local sched=Evaluator.scheduling(self.policy,pre.hp_pct)
    -- D-3: `on_new_enemy` is a preset/mode choice, so the new-enemy check runs
    -- after the mode is resolved. `continue` refreshes the known set in place
    -- (inside checkEnemies) and lets the same opportunity act.
    local newEnemy=self:checkEnemies(sched.on_new_enemy)
    if newEnemy then return self:pause(newEnemy) end
    -- AC-05: an unavailable health threshold is an executor-level unknown-safety
    -- boundary before any rule/layer evaluation (never fail open).
    local minHp=self.policy.safety and self.policy.safety.min_hp_pct
    if minHp~=nil and type(pre.hp_pct)~='number' then
        self:record({kind='paused',reason='unknown_safety',rule='health'})
        local paused=self:pause('unknown_safety')
        paused.detail='hp_pct'
        return paused
    end
    local critical=sched.low_hp
    -- AC-04: sustain maintenance is a normal-layer combat optimization; it runs
    -- before the rule loop only in the normal layer, and only with a visible
    -- enemy. An explicit normal rule (rest/auto_explore) still runs in the rule
    -- loop; if nothing matches, the no-enemy mode decides the stop reason.
    if sched.layer=='normal' and (pre.enemy_count or 0)>0 then
        local sustain=self:sustainStep()
        if sustain then
            local outcome=(self.host and self.host.request and self.host.request({
                rule='sustain:'..sustain.talent,action='set_sustain',talent=sustain.talent,
                target='self',generation=generation})) or {}
            -- R-1 (round anor-reg-01 fix2): the action budget counts native
            -- submissions that took effect (a completed action or a charged
            -- attempt). A settled refusal that produced no native action and
            -- spent no energy does not consume it.
            if outcome.status=='ok' or outcome.energy_spent==true then
                self.attempts=self.attempts+1
            end
            if outcome.status=='native_pending' then
                self.state='waiting_native'; self.reason='native_pending'
                return {action='wait_native',rule='sustain:'..sustain.talent,state=self.state,generation=generation}
            end
            if outcome.status=='ok' then
                self.actions=self.actions+1
                self:countInstant(outcome)
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
    end
    for _=1,8 do
        local ctx=self:context(default_selector)
        ctx.attempts=self.attempts
        ctx.denied=self.denied
        local decision=Evaluator.evaluate(self.policy,ctx,{context_for=function(selector)
            if selector==default_selector then return ctx end
            local rc=self:context(selector)
            rc.attempts=self.attempts
            rc.denied=self.denied
            return rc
        end})
        if decision.decision=='pause' then
            -- R-1 (round anor-reg-01 fix2): the emergency-refusal terminal (a
            -- settled reject left nothing applicable in this opportunity) must
            -- not pause with the lease held: nothing was submitted, the world
            -- is frozen and no cooldown could ever decay, so every resume would
            -- replay the same rejected action. That is the same integrity exit
            -- as the no-rule hold: stop the run with the typed refusal reason
            -- and let the service release the lease. The reason stays honest
            -- (`action_denied`), and `start` re-acquires explicitly.
            if decision.reason=='action_denied' and decision.fallback then
                self:record({kind='stopped',reason=decision.reason,rule=decision.rule})
                self:stop(decision.reason)
                return {action='stopped',reason=decision.reason,rule=decision.rule,
                    results=decision.results,rejections=self.rejections,
                    state=self.state,generation=self.generation}
            end
            self:record({kind='paused',reason=decision.reason,rule=decision.rule})
            local paused=self:pause(decision.reason)
            paused.results=decision.results; paused.rejections=self.rejections
            return paused
        end
        if decision.decision=='hold' then
            -- No idle waiting: when there is no executable rule the run ends and
            -- explains why, returning control. The no-enemy mode chooses the
            -- reason (`stop` = legacy `no_visible_enemies`).
            local holdreason='no_available_action'
            if ctx.enemy_count==0 and sched.on_no_enemy=='stop' then holdreason='no_visible_enemies' end
            self:record({kind='stopped',reason=holdreason})
            self:stop(holdreason)
            return {action='stopped',reason=holdreason,results=decision.results,
                rejections=self.rejections,state=self.state,generation=self.generation}
        end
        -- AC-06: the instant cap is applied before another instant-capable
        -- submission in the same opportunity.
        if (decision.action=='use_talent' or decision.action=='set_sustain') and self:instantBudgetExhausted() then
            self:record({kind='paused',reason='instant_budget_exhausted',rule=decision.rule})
            local paused=self:pause('instant_budget_exhausted')
            paused.results=decision.results; paused.rejections=self.rejections
            return paused
        end
        local bound=self:rebind(ctx,decision)
        if bound==nil then
            self:deny(decision.rule,'target_rebind_failed')
        else
            -- Movement/reposition: resolve the pure-data destination selector
            -- against player-known info and the policy's explicit accept object.
            -- A policy rejection is not a native call attempt; deny the rule and
            -- let an independent rule be evaluated (fail closed only for
            -- execution non-determinability, never for strategy).
            local plan
            if decision.action=='move' or decision.destination~=nil or decision.target_plan~=nil then
                if self.host and type(self.host.plan)=='function' then
                    local planned,planned_err=self.host.plan({
                        rule=decision.rule,action=decision.action,talent=decision.talent,
                        destination=decision.destination,target_plan=decision.target_plan,
                        direction=decision.direction,
                        target=decision.target,bound_target=bound.bound_target,
                        exclude=self.rejected_landings})
                    if planned and planned.plan then
                        plan=planned.plan
                    else
                        local reason=(planned and planned.reason)
                            or (planned_err and planned_err.reason) or 'destination_unavailable'
                        local detail=(planned_err and planned_err.annotation)
                            or (planned_err and planned_err) or (planned and planned.annotation)
                        if reason=='unsupported_target_plan' then
                            -- An ordered multi-prompt plan cannot be driven by the
                            -- one-prompt executor; pause with a typed capability
                            -- reason instead of silently ignoring the rest.
                            self:record({kind='paused',reason=reason,rule=decision.rule,detail=boundedDetail(detail)})
                            local paused=self:pause(reason)
                            paused.results=decision.results;paused.rejections=self.rejections
                            return paused
                        end
                        self:deny(decision.rule,reason,detail)
                    end
                else
                    self:deny(decision.rule,'movement_provider_unavailable')
                end
            end
            -- P2-1 integrity: a plan whose deterministic landing was already
            -- refused this opportunity must never be resubmitted (a provider
            -- that ignored `exclude` would otherwise loop within the budget).
            if plan then
                local key=self.landingKey(plan)
                if key and self.rejected_landings[key] then
                    self:deny(decision.rule,'native_rejected')
                end
            end
            if not self.denied[decision.rule] then
            -- Q4: the guard measures the actual known self/friendly risk and
            -- compares it with the policy's `max_selffire_risk`. A known risk at
            -- or under the threshold is permitted (detail carried for logging);
            -- above the threshold or an incalculable footprint is a policy
            -- rejection of this action (try the next rule), not a global veto.
            local guard=self.host and self.host.guard and self.host.guard({
                rule=decision.rule,action=decision.action,talent=decision.talent,
                target=decision.target,bound_target=bound.bound_target,
                plan=plan,emergency=decision.emergency==true})
            if guard and guard.action=='pause' then
                self:record({kind='paused',reason=guard.reason,rule=decision.rule,
                    detail=boundedDetail(guard.detail)})
                local paused=self:pause(guard.reason)
                paused.results=decision.results;paused.rejections=self.rejections
                return paused
            end
            if guard and guard.action=='reject' then
                -- R-1 (round anor-reg-01 fix2): a guard rejection is a
                -- pre-execution refusal: it never reaches the native executor,
                -- produces no native action and must not consume the action
                -- budget (with max_actions_per_tick=1 a consumed budget would
                -- freeze the fall-through and livelock a held lease). Deny the
                -- rule and try the next candidate; the per-opportunity work
                -- stays bounded by the denied-rule set and the rule-loop cap.
                self:deny(decision.rule,guard.reason or 'safety_rejected',guard.detail)
            else
            local guard_detail=guard and guard.detail
            local outcome=(self.host and self.host.request and self.host.request({
                rule=decision.rule,action=decision.action,talent=decision.talent,
                emergency=decision.emergency==true,
                max_turns=decision.max_turns,direction=decision.direction,
                destination=decision.destination,target_plan=decision.target_plan,plan=plan,
                target=decision.target,bound_target=bound.bound_target,generation=generation})) or {}
            -- S2 rev3: the ordered prompt-response queue deviation rides on the
            -- `native_pending` result, so it MUST be checked BEFORE the budget
            -- increment and BEFORE the `native_pending` branch — otherwise the
            -- pause (and the service's lease release) would be unreachable and
            -- the run would enter `waiting_native` instead. The plugin could not
            -- answer the k-th native prompt with the k-th declared value (a
            -- signature mismatch, a reordered flow, an extra prompt, an
            -- unreadable spec, a missing non-optional entry, or an unevaluable
            -- value), so it pauses with the typed reason and NEVER resubmits.
            -- A settled queue deviation does not consume the action budget; this
            -- is a post-commit integrity pause, not a strategy refusal and not a
            -- native-landing exclusion.
            if outcome.sequence_deviation then
                local reason=outcome.sequence_deviation.reason or 'unexpected_target_request'
                -- S2-FIX5: the typed deviation event ITSELF reaches the policy
                -- log with its rule and bounded detail; the pause transition
                -- must not emit a second, detail-less event (the live S2
                -- playtest's paused `unexpected_target_request` records carried
                -- no detail and no rule, because `pause`'s bare notify was the
                -- only event the log ever saw). Mirror `nativeDeviated`:
                -- notify the detailed entry, move to paused, and let `pause`
                -- deduplicate so exactly one typed event is logged.
                local entry={kind='paused',reason=reason,rule=decision.rule,
                    detail=boundedDetail(outcome.sequence_deviation),
                    handed_back=outcome.handed_back==true or nil}
                self:record(entry)
                if self.notify then self.notify(entry) end
                if self.state~='paused' or self.reason~=reason then
                    self.generation=self.generation+1
                    self.state='paused'; self.reason=reason
                end
                local paused=self:pause(reason)
                paused.detail=outcome.sequence_deviation
                -- `handed_back` is evidence only (the reason drives the pause);
                -- it marks that a LIVE native prompt was handed to the
                -- player/caller, so the caller can answer it via
                -- respond/dismiss after the lease is released.
                if outcome.handed_back then paused.handed_back=true end
                paused.results=decision.results;paused.rejections=self.rejections
                return paused
            end
            -- R-1 (round anor-reg-01 fix2): the action budget counts native
            -- submissions that took effect (a completed action or a charged
            -- attempt). A settled refusal that produced no native action and
            -- spent no energy does not consume it, so the same-opportunity
            -- fall-through stays available even at max_actions_per_tick=1. The
            -- opportunity stays bounded without the budget: every refused rule
            -- is denied for the rest of the opportunity (movement retries are
            -- bounded by the excluded-landing set) and the rule loop below is
            -- hard-capped. budget_exhausted therefore always means "this
            -- opportunity already completed max charged actions", never "the
            -- cause was a refusal".
            if outcome.status=='ok' or outcome.energy_spent==true then
                self.attempts=self.attempts+1
            end
            -- MFT-REV-06: a scene transition is scene-boundary evidence,
            -- independent of the outcome status. Any started/completed
            -- transition stops/resets the run and requires an explicit start on
            -- the new scene (uncertainty is preserved in the diagnostic).
            if outcome.level_changed==true then
                self:record({kind='scene_changed',rule=decision.rule,outcome=outcome})
                self:stop('level_changed')
                return {action='stopped',reason='level_changed',rule=decision.rule,
                    results=decision.results,rejections=self.rejections,outcome=outcome,
                    state=self.state,generation=self.generation}
            end
            if outcome.status=='native_pending' then
                self.state='waiting_native'; self.reason='native_pending'
                return {action='wait_native',rule=decision.rule,state=self.state,generation=generation}
            end
            if outcome.status=='ok' then
                self.actions=self.actions+1
                self:countInstant(outcome)
                self:record({kind='acted',rule=decision.rule,talent=decision.talent,
                    target=bound.bound_target,destination=plan and plan.annotation,
                    reduced=outcome.reduced==true or nil,
                    reduced_reason=outcome.reduced_reason,
                    target_sequence=outcome.target_sequence,
                    detail=boundedDetail(guard_detail)})
                return {action='acted',rule=decision.rule,talent=decision.talent,bound_target=bound.bound_target,
                    destination=plan and plan.annotation,risk=boundedDetail(guard_detail),
                    reduced=outcome.reduced==true or nil,reduced_reason=outcome.reduced_reason,
                    target_sequence=outcome.target_sequence,
                    results=decision.results,rejections=self.rejections,outcome=outcome,
                    state=self.state,generation=generation}
            end
            if outcome.status=='rejected' and outcome.code=='change_level_pending' then
                -- A native dialog opened during the scene transition; hand the
                -- interaction back rather than resubmitting.
                return self:pause('player_interaction')
            end
            if outcome.status=='rejected' and outcome.energy_spent~=true then
                -- Explicitly rejected and no energy spent. For a deterministic
                -- movement landing this is a native collision/refusal of one
                -- coordinate: exclude it and re-plan the same selector/anchor
                -- so an acceptable alternative is tried (P2-1). No native
                -- action was produced, so the attempt does not consume the
                -- budget (R-1); the retries are bounded by the excluded-landing
                -- set and the rule-loop cap. Every other action keeps the
                -- frozen behavior: do not retry as-is in this opportunity, but
                -- another rule may still be valid.
                local key=self.landingKey(plan)
                if key and not self.rejected_landings[key] then
                    self.rejected_landings[key]=true
                    self:movementRetry({rule=decision.rule,talent=decision.talent,
                        action=decision.action,landing=key,code=outcome.code,
                        generation=generation})
                else
                    -- D-2: carry the typed refusal detail (native cooldown
                    -- `missing`, `hint`, `native_message`) into the policy log.
                    self:deny(decision.rule,'native_rejected',
                        {missing=outcome.missing,hint=outcome.hint,native_message=outcome.native_message,landing=key})
                end
            else
                return self:pause(outcome.status=='rejected' and 'action_denied' or 'action_uncertain')
            end
            end
            end
        end
    end
    -- R-1 (round anor-reg-01 fix2): the rule-loop cap is the bound that replaced
    -- attempt counting for refusals. Exhaustion without any charged action means
    -- the world is frozen and the run cannot progress: stop (release the lease)
    -- instead of pausing with the lease held. With charged actions the world
    -- advances on its own, so the ordinary pause keeps its meaning.
    if self.attempts==0 then
        self:record({kind='stopped',reason='rule_loop_limit'})
        self:stop('rule_loop_limit')
        return {action='stopped',reason='rule_loop_limit',rejections=self.rejections,
            state=self.state,generation=self.generation}
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
