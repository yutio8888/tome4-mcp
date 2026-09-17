-- Movement / repositioning first tranche (MOV-1..MOV-5).
--
-- Pure deterministic planner units (schema acceptance, selector ranking,
-- uncertainty annotation, no RNG) plus production-path controller/executor
-- wiring for a plain step, a grid talent, a random self-teleport and the
-- `change_level` scene lifecycle.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Planner=require 'mod.auto_combat.MovementPlanner'
local Evaluator=require 'mod.auto_combat.PolicyEvaluator'
local Schema=require 'mod.auto_combat.PolicySchema'
local AutoCombat=require 'mod.auto_combat.AutoCombat'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- A tiny player-known map provider. `cells` maps "x,y" -> knowledge; any cell not
-- listed is in-bounds and fully unknown.
local function provider(origin,cells,anchors)
    return {
        origin=function() return {x=origin.x,y=origin.y} end,
        anchor=function(name)
            if anchors and anchors[name] then return anchors[name] end
            if name=='self' then return {x=origin.x,y=origin.y} end
            return nil
        end,
        knowledge=function(x,y)
            local known=cells and cells[x..','..y]
            if known then return known end
            return {in_bounds=true}
        end,
    }
end
local function accept(overrides)
    local a={visibility='any',passability='native',hazard='any',landing='allow_random'}
    for k,v in pairs(overrides or {}) do a[k]=v end
    return a
end

-- 1. Pure planner: selectors, acceptance, annotation, determinism ------------
do
    local cells={
        ['3,2']={in_bounds=true,visible=true,remembered=true,passable=true,hazard=true},
        ['1,2']={in_bounds=true,visible=true,remembered=true,passable=true,hazard=true},
        ['2,1']={in_bounds=true,passable=false},
    }
    local p=provider({x=2,y=2},cells,{bound_target={x=6,y=2}})
    local step=Planner.planStep({selector='toward',anchor='bound_target',accept=accept()},p,1)
    check(step and step.kind=='step' and step.direction==9,
        'toward chooses the adjacent cell that reduces distance to the bound target')
    local away=Planner.planStep({selector='away',anchor='bound_target',accept=accept()},p,1)
    check(away and away.direction==7,'away chooses the adjacent cell that increases distance')
    local pref=Planner.planStep({selector='preferred_distance',anchor='bound_target',distance=5,
        accept=accept()},p,1)
    check(pref and pref.direction~=nil,'preferred_distance chooses a deterministic adjacent cell')
    local position=Planner.planStep({selector='position',x=1,y=2,accept=accept()},p,1)
    check(position and position.direction==4 and position.x==1 and position.y==2,
        'position resolves to the adjacent step toward the requested cell')
    local relative=Planner.planStep({selector='relative',dx=1,dy=1,accept=accept()},p,1)
    check(relative and relative.direction==3 and relative.x==3 and relative.y==3,
        'relative resolves (self+dx,self+dy)')
    -- Determinism: the same provider yields the identical plan, and the planner
    -- never calls RNG.
    local math_random=math.random
    math.random=function() error('planner must not use RNG') end
    local a=Planner.planStep({selector='toward',anchor='bound_target',accept=accept()},p,1)
    local b=Planner.planStep({selector='toward',anchor='bound_target',accept=accept()},p,1)
    check(a.direction==b.direction and a.x==b.x and a.y==b.y,'planner output is deterministic and RNG-free')
    math.random=math_random
end

-- 2. Acceptance filters are policy-owned, never plugin strategy gates ---------
do
    local cells={['3,2']={in_bounds=true,visible=false,remembered=true,passable='unknown',hazard='unknown'},
        ['2,1']={in_bounds=true,visible=true,remembered=true,passable=true,hazard=true}}
    local p=provider({x=2,y=2},cells,{bound_target={x=6,y=2}})
    local seen=Planner.planStep({selector='toward',anchor='bound_target',
        accept=accept({visibility='known'})},p,1)
    check(seen and seen.x==3 and seen.y==2,'a remembered (out-of-vision) cell is accepted by visibility=known')
    check(seen.annotation.visible==false and seen.annotation.remembered==true,
        'the annotation reports visibility and memory honestly')
    check(seen.annotation.known_passable=='unknown' and seen.annotation.known_hazard=='unknown',
        'unknown passability/hazard stay unknown, never labelled safe')
    local visibleOnly=Planner.planStep({selector='toward',anchor='bound_target',
        accept=accept({visibility='visible'})},p,1)
    check(visibleOnly and visibleOnly.x==2 and visibleOnly.y==1,
        'visibility=visible filters out the remembered cell (policy, not a plugin gate)')
    local hazardAvoid=Planner.planStep({selector='position',x=2,y=1,
        accept=accept({visibility='any',hazard='avoid_known'})},p,1)
    check(not (hazardAvoid and hazardAvoid.direction==8),
        'avoid_known never selects a destination with a known hazard')
    local unknownHazard=Planner.planStep({selector='position',x=3,y=2,
        accept=accept({visibility='any',hazard='avoid_known'})},p,1)
    check(unknownHazard and unknownHazard.x==3 and unknownHazard.y==2,
        'avoid_known keeps an unknown-hazard destination (policy decides)')
    local knownSafe=Planner.planStep({selector='toward',anchor='bound_target',
        accept=accept({hazard='known_safe'})},p,1)
    check(knownSafe==nil,'known_safe fails closed when no affirmative safe proof exists')
    -- Polarity: a provider cell with `hazard=false` is affirmatively safe and is
    -- accepted by known_safe / avoid_known.
    local safeCells={['3,2']={in_bounds=true,visible=true,remembered=true,passable=true,hazard=false}}
    local sp=provider({x=2,y=2},safeCells,{bound_target={x=6,y=2}})
    local safe=Planner.planStep({selector='position',x=3,y=2,
        accept=accept({hazard='known_safe'})},sp,1)
    check(safe and safe.x==3 and safe.y==2,'hazard=false is affirmatively safe (known_safe accepts it)')
end

-- 3. Talent destinations: grid, native landing, random teleport --------------
do
    local p=provider({x=2,y=2},{['5,5']={in_bounds=true,visible=false,remembered=false,passable='unknown',hazard='unknown'}})
    local grid=Planner.planTalent({selector='position',x=5,y=5,accept=accept()},p,nil,
        {target_requests={'grid'},landing='exact'})
    check(grid and grid.kind=='grid' and grid.x==5 and grid.y==5,
        'a grid request is passed through with its unknown annotation')
    check(grid.annotation.visible==false and grid.annotation.known_passable=='unknown',
        'an out-of-vision grid request is annotated, not refused')
    local random=Planner.planTalent({selector='native_random',accept=accept()},p,nil,
        {target_requests={'none'},landing='random',radius=6,min_radius=1})
    check(random and random.kind=='native_random','native_random produces no fictitious endpoint')
    check(random.annotation.landing.kind=='random' and random.annotation.landing.radius==6,
        'native_random reports the source-declared random landing envelope')
    check(random.annotation.confidence=='source_pinned_random','the random landing carries its confidence')
    local strict=Planner.planTalent({selector='native_random',accept=accept({landing='deterministic'})},p,nil,
        {target_requests={'none'},landing='random'})
    check(strict==nil,'landing=deterministic is a policy rejection of a random landing, not a plugin veto')
    local landing=Planner.planTalent({selector='native_landing',anchor='bound_target',accept=accept()},
        provider({x=2,y=2},{},{bound_target={x=6,y=2}}),1,{target_requests={'actor'},landing='bounded_alternatives',radius=1})
    check(landing and landing.kind=='native_landing','an actor-anchored landing uses the native envelope')
    check(landing.annotation.landing.kind=='bounded','a bounded landing is reported as bounded')
    -- MFT-REV-04: `bounded` is a non-single landing; `landing='deterministic'`
    -- must reject it (not only `random`).
    local boundedStrict=Planner.planTalent({selector='native_landing',anchor='bound_target',
        accept=accept({landing='deterministic'})},
        provider({x=2,y=2},{},{bound_target={x=6,y=2}}),1,
        {target_requests={'actor'},landing='bounded_alternatives',radius=1})
    check(boundedStrict==nil,'landing=deterministic rejects a bounded (non-single) landing')
    local missing,missing_err=Planner.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',accept=accept()}},p,nil)
    check(missing==nil and missing_err and missing_err.reason=='unsupported_movement_adapter',
        'native_random without a movement adapter is a capability gap, not a refusal')
    -- MFT-REV-03: an ordered target plan is consumed by request kind.
    local actorPlan=Planner.plan({action='use_talent',talent='T_RUSH',bound_target='a1',
        target='nearest_hostile',
        target_plan={{request='actor',selector='nearest_hostile'}},
        destination={selector='native_landing',anchor='bound_target',accept=accept()}},
        provider({x=2,y=2},{},{bound_target={x=6,y=2}}),
        {target_requests={'actor'},landing='bounded_alternatives'})
    check(actorPlan and actorPlan.kind=='actor','a single actor target-plan step is consumed')
    -- An actor step selector that contradicts the action binding is rejected,
    -- never silently resolved to the already-bound enemy.
    local contradict,contradictErr=Planner.plan({action='use_talent',talent='T_RUSH',
        bound_target='a1',target='nearest_hostile',
        target_plan={{request='actor',selector='self'}},
        destination={selector='native_landing',anchor='bound_target',accept=accept()}},
        provider({x=2,y=2},{},{bound_target={x=6,y=2}}),
        {target_requests={'actor'},landing='bounded_alternatives'})
    check(contradict==nil and contradictErr
        and contradictErr.reason=='target_plan_selector_mismatch'
        and contradictErr.expected=='nearest_hostile' and contradictErr.got=='self',
        'a contradictory actor step selector is rejected (MFT-REV-03)')
    -- MFT-REV-03 (Option A): with no action selector, the actor step selector is
    -- the binding. A self step must use the self anchor, not the pre-bound enemy.
    local omittedSelf=Planner.plan({action='use_talent',talent='T_RUSH',bound_target='enemy-1',
        target_plan={{request='actor',selector='self'}},
        destination={selector='native_landing',anchor='bound_target',accept=accept()}},
        provider({x=2,y=2},{},{bound_target={x=6,y=2}}),
        {target_requests={'actor'},landing='bounded_alternatives'})
    check(omittedSelf and omittedSelf.kind=='actor'
        and omittedSelf.annotation.landing.center.x==2 and omittedSelf.annotation.landing.center.y==2,
        'an omitted action selector binds the self actor step, not the pre-bound enemy')
    local omittedHostile=Planner.plan({action='use_talent',talent='T_RUSH',bound_target='enemy-1',
        target_plan={{request='actor',selector='nearest_hostile'}},
        destination={selector='native_landing',anchor='bound_target',accept=accept()}},
        provider({x=2,y=2},{},{bound_target={x=6,y=2}}),
        {target_requests={'actor'},landing='bounded_alternatives'})
    check(omittedHostile and omittedHostile.kind=='actor'
        and omittedHostile.annotation.landing.center.x==6,
        'an omitted action selector binds a hostile actor step to the bound target')
    local gridPlan=Planner.plan({action='use_talent',talent='T_SKIRMISHER_CUNNING_ROLL',
        target_plan={{request='grid',destination={selector='position',x=4,y=4,accept=accept()}}},
        destination={selector='position',x=4,y=4,accept=accept()}},
        provider({x=2,y=2},{['4,4']={in_bounds=true,visible=true,remembered=true,passable=true,hazard='unknown'}}),
        {target_requests={'grid'},landing='exact'})
    check(gridPlan and gridPlan.kind=='grid' and gridPlan.x==4,
        'a single grid target-plan step is consumed')
    local nonePlan=Planner.plan({action='use_talent',talent='T_PHASE_DOOR',
        target_plan={{request='none'}},destination={selector='native_random',accept=accept()}},
        provider({x=2,y=2},{}),{target_requests={'none'},landing='random'})
    check(nonePlan and nonePlan.kind=='none','a single none target-plan step is consumed')
    local multi,multiErr=Planner.plan({action='use_talent',talent='T_PHASE_DOOR',
        target_plan={{request='actor',selector='self'},{request='grid',
            destination={selector='away',anchor='bound_target',accept=accept()}}}},
        provider({x=2,y=2},{},{bound_target={x=6,y=2}}),
        {target_requests={'actor','grid'},landing='random'})
    check(multi==nil and multiErr and multiErr.reason=='unsupported_target_plan',
        'a multi-prompt target plan is a typed capability gap, not silently ignored')
    -- A level-limited adapter variant is rejected with the published reason.
    local variant,variantErr=Planner.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',accept=accept()}},
        {origin=function() return {x=2,y=2} end,talentLevel=function() return 4 end},
        {target_requests={'none'},landing='random',
            unsupported_variants={{at_least=4,scope='effective_talent_level>=4',
                missing='actor_then_grid_target_plan'}}})
    check(variant==nil and variantErr and variantErr.reason=='unsupported_movement_variant'
        and variantErr.missing=='actor_then_grid_target_plan',
        'a level-limited adapter variant is rejected with its typed reason')
    -- MFT-REV-08: an unknown/overridden effective level fails closed too.
    local unknownLevel,unknownErr=Planner.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',accept=accept()}},
        {origin=function() return {x=2,y=2} end,talentLevel=function() return 'unknown' end},
        {target_requests={'none'},landing='random',
            unsupported_variants={{at_least=4,scope='effective_talent_level>=4',
                missing='actor_then_grid_target_plan'}}})
    check(unknownLevel==nil and unknownErr and unknownErr.reason=='unsupported_movement_variant'
        and unknownErr.unknown==true,
        'an unknown effective level fails closed for a level-scoped variant (MFT-REV-08)')
end

-- 4. Production controller wiring: a plain step reaches the executor ----------
local function policy(overrides)
    local p={schema='tome-auto-combat/v1',id='p1',name='p1',
        limits={max_actions_per_tick=2},
        safety={min_hp_pct=35,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        rules={
            {id='kite',priority=50,when={enemy_count={ge=1}},
                ['then']={action='move',target='nearest_hostile',
                    destination={selector='away',anchor='bound_target',accept=accept()}}},
        }
    }
    for k,v in pairs(overrides or {}) do p[k]=v end
    return p
end
local function host(opts)
    local h={phase_='ready',oid=1,requests={},
        snap={hp_pct=80,enemy_count=1,bound_target='actor-1',
            resource_pct=function() return 100 end}}
    h.phase=function() return h.phase_ end
    h.opportunity_id=function() return h.oid end
    h.snapshot=function(selector) h.snap.binding_selector=selector; return h.snap end
    h.enemy_ids=function() return {} end
    h.notify=function() end
    h.plan=function(attempt)
        h.planned=attempt
        return {plan={kind='step',direction=4,annotation={landing={kind='deterministic'}}}}
    end
    h.request=function(attempt)
        h.requests[#h.requests+1]=attempt
        return (opts and opts.outcome) or {status='ok',energy_spent=1000}
    end
    return h
end
do
    local h=host()
    local c=AutoCombat.new(policy(),h,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='acted' and step.rule=='kite','a move rule acts through the planner')
    check(h.requests[1] and h.requests[1].plan and h.requests[1].plan.direction==4,
        'the planner plan reaches the executor')
    check(h.planned and h.planned.action=='move' and h.planned.destination.selector=='away',
        'the planner receives the policy destination')
end
do
    -- A destination the policy does not accept denies the rule and tries the
    -- next one, without spending a native attempt.
    local h=host()
    h.plan=function() return nil,{reason='no_acceptable_destination'} end
    h.request=function(attempt) h.requests[#h.requests+1]=attempt
        return {status='ok',energy_spent=1000} end
    local p=policy()
    p.rules={p.rules[1],{id='attack',priority=40,when={enemy_count={ge=1}},
        ['then']={action='attack',target='nearest_hostile'}}}
    local c=AutoCombat.new(p,h,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='acted' and step.rule=='attack',
        'a policy-rejected movement destination denies only that rule')
    check(h.requests[1] and h.requests[1].action=='attack','the next independent rule is evaluated')
    local denied
    for _,r in ipairs(step.rejections or {}) do if r.rule=='kite' then denied=r.reason end end
    check(denied=='no_acceptable_destination','the movement rejection is recorded with its reason')
end

-- 4b. MFT-REV-03 (Option A): an actor step selector is the controller binding
-- even when the policy declares no action/default selector.
do
    local function omittedPolicy(selector,anchor)
        return {schema='tome-auto-combat/v1',id='p1',name='p1',limits={max_actions_per_tick=1},
            safety={min_hp_pct=35},
            rules={{id='kite',priority=50,when={enemy_count={ge=1}},
                ['then']={action='use_talent',talent='T_RUSH',
                    target_plan={{request='actor',selector=selector}},
                    destination={selector='native_landing',anchor=anchor,accept=accept()}}}}}
    end
    local function omittedHost(selector)
        local h=host()
        h.snapshot=function(binding_selector)
            local bound='actor-1'
            if binding_selector=='self' or binding_selector==nil then bound=nil end
            return {hp_pct=80,enemy_count=1,binding_selector=binding_selector,
                bound_target=bound,resource_pct=function() return 100 end}
        end
        h.plan=function(attempt) h.planned=attempt
            return {plan={kind='actor',annotation={landing={kind='bounded'}}}} end
        h.request=function(attempt) h.requests[#h.requests+1]=attempt
            return {status='ok',energy_spent=1000} end
        return h
    end
    local h=omittedHost()
    local c=AutoCombat.new(omittedPolicy('nearest_hostile','bound_target'),h,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='acted' and step.rule=='kite',
        'an omitted action selector binds the declared actor step selector')
    check(h.planned and h.planned.target=='nearest_hostile' and h.planned.bound_target=='actor-1',
        'the planner receives the declared hostile actor step binding')
    local s=omittedHost()
    local sc=AutoCombat.new(omittedPolicy('self','self'),s,{strict=false})
    sc:start()
    local selfStep=sc:step()
    check(selfStep.action=='acted' and selfStep.rule=='kite',
        'an omitted action selector binds a self actor step')
    check(s.planned and s.planned.target=='self' and s.planned.bound_target==nil,
        'the planner receives the self actor step and no unrelated enemy binding')
end

-- 5. change_level lifecycle: success stops/resets and requires an explicit start
do
    local p=policy()
    p.rules={{id='descend',priority=10,when={always={}},['then']={action='change_level'}}}
    local h=host({outcome={status='ok',code='level_changed',energy_spent=0,level_changed=true}})
    local c=AutoCombat.new(p,h,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='stopped' and step.reason=='level_changed',
        'a real scene transition stops the run')
    check(c.state=='stopped','the controller is stopped after a scene change')
    local resumed=c:resume()
    check(resumed and resumed.ok==false,'a scene change requires an explicit start, not resume')
end
do
    -- A pending scene confirmation hands the interaction back instead of
    -- being counted as a completed scene change.
    local p=policy()
    p.rules={{id='descend',priority=10,when={always={}},['then']={action='change_level'}}}
    local h=host({outcome={status='rejected',code='change_level_pending',energy_spent=0}})
    local c=AutoCombat.new(p,h,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='paused' and step.reason=='player_interaction',
        'a pending change_level confirmation pauses for the player')
end

-- 5b. An uncertain scene change still stops/resets (MFT-REV-06).
do
    local p=policy()
    p.rules={{id='descend',priority=10,when={always={}},['then']={action='change_level'}}}
    local h=host({outcome={status='uncertain',code='execution_error',energy_spent=0,
        level_changed=true}})
    local c=AutoCombat.new(p,h,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='stopped' and step.reason=='level_changed',
        'an uncertain outcome that still changed level stops the run')
    check(c.state=='stopped','the controller is stopped, not merely paused')
    check(c:resume().ok==false,'an uncertain scene change requires an explicit start')
end

-- 5c. v1.6 mode: evaluate_rules executes a policy kite below min_hp_pct -------
do
    local p=policy({mode={on_low_hp='evaluate_rules'}})
    local h=host()
    h.snap.hp_pct=10
    local c=AutoCombat.new(p,h,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='acted' and step.rule=='kite',
        'evaluate_rules executes a policy movement rule at low HP (no global flee gate)')
end

-- 5d. Q4: a within-tolerance guard permit surfaces the measurement -----------
do
    local p=policy()
    local h=host()
    h.guard=function() return {action='permit',detail={measurement=40,threshold=50,
        phase='instant',provenance={selffire='explicit'}}} end
    local c=AutoCombat.new(p,h,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='acted' and step.risk and step.risk.measurement==40
        and step.risk.threshold==50,'a permitted action carries the measured risk and threshold')
    local recent=c:recentDecisions(4)
    local carried=false
    for _,event in ipairs(recent) do
        if event.kind=='acted' and event.detail and event.detail.measurement==40 then carried=true end
    end
    check(carried,'the guard measurement reaches the bounded decision ring')
end

-- 5e. A rejected guard risk carries its detail into the denial record --------
do
    local p=policy()
    local h=host()
    h.guard=function() return {action='reject',reason='selffire_risk',
        detail={measurement=90,threshold=0,unknown=false}} end
    local c=AutoCombat.new(p,h,{strict=false})
    c:start()
    c:step()
    local found
    for _,r in ipairs(c.rejections or {}) do
        if r.rule=='kite' then found=r.detail end
    end
    check(found and found.measurement==90 and found.threshold==0,
        'the guard risk detail is retained with the denial (MFT-REV-07)')
end

-- 5f. A multi-prompt target plan pauses with a typed reason ------------------
do
    local p=policy()
    p.rules={{id='door',priority=10,when={always={}},
        ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
            target_plan={{request='actor',selector='self'},{request='grid',
                destination={selector='relative',dx=1,dy=0,accept=accept()}}}}}}
    local h=host()
    h.plan=function() return nil,{reason='unsupported_target_plan',count=2} end
    local c=AutoCombat.new(p,h,{strict=false})
    c:start()
    local step=c:step()
    check(step.action=='paused' and step.reason=='unsupported_target_plan',
        'a multi-prompt target plan pauses with a typed capability reason')
end

-- 6. Schema/decision carry the destination through to the planner -------------
do
    local decision=Evaluator.evaluate(policy(),{hp_pct=80,enemy_count=1,attempts=0})
    check(decision.decision=='act' and decision.action=='move'
        and decision.destination and decision.destination.selector=='away',
        'the evaluator carries the pure-data destination into the decision')
    check(Schema.validate(policy()),'the movement policy validates')
end

print('Auto-combat movement: '..checks..' checks passed')
