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
        ['2,1']={in_bounds=true,visible=true,remembered=true,passable=true,hazard=false}}
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
    check(knownSafe==nil,'known_safe fails closed when no affirmative hazard proof exists')
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
    local missing,missing_err=Planner.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',accept=accept()}},p,nil)
    check(missing==nil and missing_err and missing_err.reason=='unsupported_movement_adapter',
        'native_random without a movement adapter is a capability gap, not a refusal')
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
    h.snapshot=function() return h.snap end
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

-- 6. Schema/decision carry the destination through to the planner -------------
do
    local decision=Evaluator.evaluate(policy(),{hp_pct=80,enemy_count=1,attempts=0})
    check(decision.decision=='act' and decision.action=='move'
        and decision.destination and decision.destination.selector=='away',
        'the evaluator carries the pure-data destination into the decision')
    check(Schema.validate(policy()),'the movement policy validates')
end

print('Auto-combat movement: '..checks..' checks passed')
