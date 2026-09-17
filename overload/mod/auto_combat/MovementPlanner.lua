-- GPL-3.0-or-later. Pure, deterministic movement-destination planner.
--
-- The plugin is a faithful executor, not a tactician: this module turns a
-- policy's pure-data `destination` request into one concrete native request
-- (a keypad step or a grid coordinate) plus an honest player-known annotation.
-- It never rolls RNG, never reads hidden state and never filters a destination
-- for strategic reasons. Whether a reported uncertainty is acceptable is the
-- policy's explicit `accept` object, which this module evaluates.
--
-- The planner contract (`provider`) is injected so the same code runs in unit
-- tests and in the live executor:
--   provider.origin()            -> {x=,y=}
--   provider.anchor(name,bound)  -> {x=,y=}|nil   (name 'self'|'bound_target')
--   provider.knowledge(x,y)      -> {in_bounds=bool, visible=bool,
--                                    remembered=bool,
--                                    passable=true|false|'unknown',
--                                    hazard=true|false|'unknown'}
--
-- `M.plan(attempt, provider, movement)` returns a plan table:
--   {kind='step'|'grid'|'native_landing'|'native_random'|'none',
--    direction=,x=,y=,annotation={...}}
-- or `nil, {reason=..., annotation=...}`. The `reason` is an execution-integrity
-- or capability reason (unresolvable anchor, unsupported adapter) or a policy
-- acceptance reason (`visibility`/`passability`/`hazard`/`landing`) -- never a
-- strategic refusal.
local Distance=require 'mod.mcp_bridge.Distance'
local M={}

M.SELECTORS={toward=true,away=true,preferred_distance=true,position=true,relative=true,
    native_landing=true,native_random=true}
-- `move` is a single adjacent step; the anchor-relative and coordinate selectors
-- are meaningful for it, but the native-landing selectors belong to talents.
M.STEP_SELECTORS={toward=true,away=true,preferred_distance=true,position=true,relative=true}
-- `toward/away/preferred_distance` for a talent request a grid coordinate that
-- the audited native builder then validates.
M.TALENT_SELECTORS={toward=true,away=true,preferred_distance=true,position=true,relative=true,
    native_landing=true,native_random=true}
M.ANCHORS={bound_target=true,self=true}

M.VISIBILITY={visible=true,known=true,any=true}
M.PASSABILITY={known_passable=true,native=true}
M.HAZARD={known_safe=true,avoid_known=true,any=true}
M.LANDING={deterministic=true,allow_random=true}

-- Fixed keypad order. Candidate generation and tie-breaks are deterministic and
-- never consult table iteration order or RNG (design §4).
M.DIRECTIONS={7,8,9,4,6,1,2,3}
M.DELTAS={[7]={-1,-1},[8]={0,-1},[9]={1,-1},[4]={-1,0},[6]={1,0},[1]={-1,1},[2]={0,1},[3]={1,1}}
-- Bounded grid scan for talent destinations whose exact request is not given.
-- Native range/collision remains final authority; this only bounds candidate
-- enumeration (integrity, not strategy).
M.SCAN_RADIUS=12

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end

-- Annotate one cell from player-known information only. `unknown` is a value,
-- never a substitute for a hidden-state read.
function M.annotate(x,y,provider)
    local knowledge=provider.knowledge and provider.knowledge(x,y) or nil
    knowledge=knowledge or {}
    local passable=knowledge.passable
    local hazard=knowledge.hazard
    if passable==nil then passable='unknown' end
    if hazard==nil then hazard='unknown' end
    local visible=knowledge.visible==true
    local remembered=knowledge.remembered==true
    local reasons={}
    if knowledge.in_bounds==false then reasons[#reasons+1]='out_of_bounds' end
    if not visible then reasons[#reasons+1]='not_currently_visible' end
    if not remembered then reasons[#reasons+1]='not_remembered' end
    if passable=='unknown' then reasons[#reasons+1]='passability_unknown' end
    if hazard=='unknown' then reasons[#reasons+1]='hazard_unknown' end
    return {x=x,y=y,in_bounds=knowledge.in_bounds~=false,
        visible=visible,remembered=remembered,
        known_passable=passable,known_hazard=hazard,
        landing={kind='deterministic',x=x,y=y},
        confidence='player_known',reasons=reasons}
end

-- A landing is deterministic only when the source proves a single landing.
-- `bounded` (bounded native alternatives) and `random` are both non-single and
-- require the policy's `landing='allow_random'`.
local function isNonDeterministicLanding(landing)
    if type(landing)~='table' then return true end
    return landing.kind~='deterministic'
end

-- Evaluate the policy's explicit acceptance object against an annotation. All
-- four fields are required by the schema, so there is no hidden plugin default.
-- Hazard polarity: `known_hazard=true` is a known hazard, `false` is an
-- affirmative safe result, `'unknown'` is unknown.
function M.accepts(accept,annotation)
    accept=accept or {}
    if accept.visibility=='visible' and annotation.visible~=true then return false,'visibility' end
    if accept.visibility=='known' and not (annotation.visible==true or annotation.remembered==true) then
        return false,'visibility'
    end
    if accept.passability=='known_passable' and annotation.known_passable~=true then
        return false,'passability'
    end
    if accept.hazard=='known_safe' and annotation.known_hazard~=false then return false,'hazard' end
    if accept.hazard=='avoid_known' and annotation.known_hazard==true then return false,'hazard' end
    if accept.landing=='deterministic' and isNonDeterministicLanding(annotation.landing) then
        return false,'landing'
    end
    return true
end

-- Score a candidate for the selector. Lower is better except `away`, which
-- negates the distance so the existing ascending comparison maximises it.
local function score(selector,origin,anchor,x,y,distance)
    if selector=='toward' then return Distance.grid(x,y,anchor.x,anchor.y) end
    if selector=='away' then return -Distance.grid(x,y,anchor.x,anchor.y) end
    if selector=='preferred_distance' then return math.abs(Distance.grid(x,y,anchor.x,anchor.y)-distance) end
    -- position/relative: prefer the candidate that reaches the requested cell
    -- (the anchor for those selectors is the requested coordinate).
    return Distance.grid(x,y,anchor.x,anchor.y)
end

-- Deterministic ranking: score, then distance from origin, then y, then x.
local function better(a,b)
    if a.score~=b.score then return a.score<b.score end
    if a.origin_distance~=b.origin_distance then return a.origin_distance<b.origin_distance end
    if a.y~=b.y then return a.y<b.y end
    if a.x~=b.x then return a.x<b.x end
    return false
end

local function anchorFor(request,provider,bound,origin)
    if request.selector=='position' then return {x=request.x,y=request.y} end
    if request.selector=='relative' then return {x=origin.x+request.dx,y=origin.y+request.dy} end
    return provider.anchor and provider.anchor(request.anchor,bound) or nil
end

-- Plan one adjacent step for a `move` action.
function M.planStep(request,provider,bound,origin)
    origin=origin or (provider.origin and provider.origin())
    if not origin then return nil,{reason='origin_unavailable'} end
    if request.selector and not M.STEP_SELECTORS[request.selector] then
        return nil,{reason='unsupported_selector_for_move',selector=request.selector}
    end
    local anchor=anchorFor(request,provider,bound,origin)
    if (request.selector=='toward' or request.selector=='away'
            or request.selector=='preferred_distance') and not anchor then
        return nil,{reason='anchor_unavailable',selector=request.selector}
    end
    local best
    for _,direction in ipairs(M.DIRECTIONS) do
        local delta=M.DELTAS[direction]
        local x,y=origin.x+delta[1],origin.y+delta[2]
        local annotation=M.annotate(x,y,provider)
        if annotation.in_bounds then
            local ok,reason=M.accepts(request.accept,annotation)
            if ok then
                local candidate={direction=direction,x=x,y=y,annotation=annotation,
                    score=score(request.selector,origin,anchor,x,y,request.distance),
                    origin_distance=Distance.grid(origin.x,origin.y,x,y)}
                if not best or better(candidate,best) then best=candidate end
            else
                annotation.rejection=reason
            end
        end
    end
    if not best then return nil,{reason='no_acceptable_destination',selector=request.selector} end
    best.annotation.selector=request.selector
    best.annotation.landing={kind='deterministic',direction=best.direction,x=best.x,y=best.y}
    best.annotation.reasons[#best.annotation.reasons+1]='native_collision_authoritative'
    return {kind='step',direction=best.direction,x=best.x,y=best.y,
        annotation=best.annotation,score=best.score}
end

-- Plan a talent destination. `movement` is the manifest's movement adapter (or
-- nil, which is a capability gap for the native-landing selectors).
function M.planTalent(request,provider,bound,movement,origin)
    origin=origin or (provider.origin and provider.origin())
    if not origin then return nil,{reason='origin_unavailable'} end
    movement=movement or {}
    if request.selector and not M.TALENT_SELECTORS[request.selector] then
        return nil,{reason='unsupported_selector_for_talent',selector=request.selector}
    end
    if request.selector=='native_random' then
        -- No fictitious endpoint: the native code chooses the landing.
        local bounds={kind='random',source='native'}
        if finite(movement.radius) then bounds.radius=movement.radius end
        if finite(movement.min_radius) then bounds.min_radius=movement.min_radius end
        if finite(movement.range) then bounds.range=movement.range end
        local annotation={landing=bounds,visible=false,remembered=false,
            known_passable='unknown',known_hazard='unknown',
            confidence='source_pinned_random',
            reasons={'native_random_landing','hidden_occupancy_not_inspected'}}
        local ok,reason=M.accepts(request.accept,annotation)
        if not ok then return nil,{reason=reason,annotation=annotation} end
        return {kind='native_random',annotation=annotation}
    end
    if request.selector=='native_landing' then
        local anchor=anchorFor(request,provider,bound,origin)
        if not anchor then return nil,{reason='anchor_unavailable',selector=request.selector} end
        -- `exact` is a single source-proven landing; `bounded_alternatives` is a
        -- source-bounded native choice and is treated as random for acceptance.
        local kind=movement.landing=='exact' and 'deterministic' or 'bounded'
        local landing={kind=kind,center={x=anchor.x,y=anchor.y}}
        if finite(movement.radius) then landing.radius=movement.radius end
        if finite(movement.min_radius) then landing.min_radius=movement.min_radius end
        local annotation={landing=landing,visible=true,remembered=true,
            known_passable='unknown',known_hazard='unknown',
            confidence='source_'..tostring(movement.landing or 'defined'),
            reasons={'actor_anchored_landing','landing_derived_by_native'}}
        local ok,reason=M.accepts(request.accept,annotation)
        if not ok then return nil,{reason=reason,annotation=annotation} end
        return {kind='native_landing',annotation=annotation}
    end
    if request.selector=='position' or request.selector=='relative' then
        local x,y
        if request.selector=='position' then x,y=request.x,request.y
        else x,y=origin.x+request.dx,origin.y+request.dy end
        local annotation=M.annotate(x,y,provider)
        if annotation.in_bounds==false then
            return nil,{reason='destination_out_of_bounds',x=x,y=y,annotation=annotation}
        end
        local ok,reason=M.accepts(request.accept,annotation)
        if not ok then return nil,{reason=reason,annotation=annotation} end
        annotation.selector=request.selector
        annotation.reasons[#annotation.reasons+1]='native_builder_validates_request'
        return {kind='grid',x=x,y=y,annotation=annotation}
    end
    -- toward/away/preferred_distance: bounded scan around the origin, in y,x
    -- order, annotated from player-known info and filtered only by `accept`.
    local anchor=anchorFor(request,provider,bound,origin)
    if not anchor then return nil,{reason='anchor_unavailable',selector=request.selector} end
    local radius=finite(movement.range) and math.floor(movement.range) or M.SCAN_RADIUS
    if radius<1 then radius=1 end
    if radius>M.SCAN_RADIUS then radius=M.SCAN_RADIUS end
    local best
    for dy=-radius,radius do
        for dx=-radius,radius do
            if not (dx==0 and dy==0) then
                local x,y=origin.x+dx,origin.y+dy
                local annotation=M.annotate(x,y,provider)
                if annotation.in_bounds then
                    local ok=M.accepts(request.accept,annotation)
                    if ok then
                        local candidate={x=x,y=y,annotation=annotation,
                            score=score(request.selector,origin,anchor,x,y,request.distance),
                            origin_distance=Distance.grid(origin.x,origin.y,x,y)}
                        if not best or better(candidate,best) then best=candidate end
                    end
                end
            end
        end
    end
    if not best then return nil,{reason='no_acceptable_destination',selector=request.selector} end
    best.annotation.selector=request.selector
    best.annotation.reasons[#best.annotation.reasons+1]='native_builder_validates_request'
    return {kind='grid',x=best.x,y=best.y,annotation=best.annotation,score=best.score}
end

-- Build the annotation for a no-explicit-endpoint native request (self/actor
-- landing derived by native code) from the manifest's movement classification.
local function nativeLandingAnnotation(movement,anchor)
    movement=movement or {}
    if movement.landing=='random' then
        local bounds={kind='random',source='native'}
        if finite(movement.radius) then bounds.radius=movement.radius end
        if finite(movement.min_radius) then bounds.min_radius=movement.min_radius end
        if finite(movement.range) then bounds.range=movement.range end
        return {landing=bounds,visible=false,remembered=false,
            known_passable='unknown',known_hazard='unknown',
            confidence='source_pinned_random',
            reasons={'native_random_landing','hidden_occupancy_not_inspected'}}
    end
    local kind=movement.landing=='exact' and 'deterministic' or 'bounded'
    local landing={kind=kind}
    if anchor then landing.center={x=anchor.x,y=anchor.y} end
    if finite(movement.radius) then landing.radius=movement.radius end
    if finite(movement.min_radius) then landing.min_radius=movement.min_radius end
    return {landing=landing,visible=true,remembered=true,
        known_passable='unknown',known_hazard='unknown',
        confidence='source_'..tostring(movement.landing or 'defined'),
        reasons={'actor_anchored_landing','landing_derived_by_native'}}
end

-- A source-pinned adapter may declare level/variant forms it cannot drive (for
-- example Phase Door TL4+ actor-then-grid). The runtime rejects those with the
-- same typed reason the catalog publishes (MFT-REV-08).
local function unsupportedVariant(movement,provider,talent)
    if type(movement)~='table' or type(movement.unsupported_variants)~='table' then return nil end
    local level=provider.talentLevel and provider.talentLevel(talent) or nil
    for _,variant in ipairs(movement.unsupported_variants) do
        if variant.at_least and type(level)=='number' and level>=variant.at_least then return variant end
    end
    return nil
end

-- Consume an ordered target plan: the executor pre-fills one native prompt, so
-- only a single-request plan is driven; a longer sequence is a typed capability
-- pause rather than a silent ignore.
local function planFromTargetPlan(attempt,provider,movement,origin)
    local step=attempt.target_plan[1]
    local request=step and step.request
    local accept=(type(attempt.destination)=='table') and attempt.destination.accept or nil
    local function acceptAnnotation(annotation,defaultAccept)
        local ok,reason=M.accepts(accept or defaultAccept,annotation)
        if not ok then return nil,{reason=reason,annotation=annotation} end
        return annotation,nil
    end
    if request=='grid' then
        return M.planTalent(step.destination,provider,attempt.bound_target,movement,origin)
    end
    if request=='none' then
        local annotation=nativeLandingAnnotation(movement,nil)
        local _,err=acceptAnnotation(annotation,{visibility='any',passability='native',
            hazard='any',landing='allow_random'})
        if err then return nil,err end
        return {kind='none',annotation=annotation}
    end
    if request=='self' then
        local annotation=nativeLandingAnnotation(movement,{x=origin.x,y=origin.y})
        annotation.landing.kind=(movement.landing=='exact' or movement.landing==nil)
            and 'deterministic' or annotation.landing.kind
        annotation.confidence='self_request'
        annotation.reasons={'self_request','landing_is_origin'}
        local _,err=acceptAnnotation(annotation,{visibility='any',passability='native',
            hazard='any',landing='allow_random'})
        if err then return nil,err end
        return {kind='self',annotation=annotation}
    end
    if request=='actor' then
        local anchor=provider.anchor and provider.anchor('bound_target',attempt.bound_target) or nil
        if not anchor then return nil,{reason='anchor_unavailable',selector='bound_target'} end
        local annotation=nativeLandingAnnotation(movement,anchor)
        local _,err=acceptAnnotation(annotation,{visibility='any',passability='native',
            hazard='any',landing='allow_random'})
        if err then return nil,err end
        return {kind='actor',annotation=annotation}
    end
    return nil,{reason='unsupported_target_plan',talent=attempt.talent,request=request}
end

-- Dispatch by action. `movement` is only required for native-landing selectors;
-- a missing movement adapter is a capability gap, reported as such.
function M.plan(attempt,provider,movement)
    if type(provider)~='table' then return nil,{reason='movement_provider_unavailable'} end
    local origin=provider.origin and provider.origin() or nil
    if not origin or not finite(origin.x) or not finite(origin.y) then
        return nil,{reason='origin_unavailable'}
    end
    if attempt.action=='move' then
        if type(attempt.destination)~='table' then
            -- An explicit fixed keypad direction is a complete request already.
            local direction=attempt.direction
            if finite(direction) and direction%1==0 and direction>=1 and direction<=9 and direction~=5 then
                local delta=M.DELTAS[direction]
                local annotation=M.annotate(origin.x+delta[1],origin.y+delta[2],provider)
                annotation.selector='direction'
                annotation.landing={kind='deterministic',direction=direction,
                    x=origin.x+delta[1],y=origin.y+delta[2]}
                annotation.reasons[#annotation.reasons+1]='native_collision_authoritative'
                return {kind='step',direction=direction,x=origin.x+delta[1],y=origin.y+delta[2],
                    annotation=annotation}
            end
            return nil,{reason='destination_required'}
        end
        return M.planStep(attempt.destination,provider,attempt.bound_target,origin)
    end
    local variant=unsupportedVariant(movement,provider,attempt.talent)
    if variant then
        return nil,{reason='unsupported_movement_variant',talent=attempt.talent,
            scope=variant.scope,missing=variant.missing,at_least=variant.at_least}
    end
    if type(attempt.target_plan)=='table' then
        if #attempt.target_plan~=1 then
            return nil,{reason='unsupported_target_plan',talent=attempt.talent,
                count=#attempt.target_plan,scope='multi_prompt'}
        end
        if movement==nil then
            return nil,{reason='unsupported_movement_adapter',talent=attempt.talent}
        end
        return planFromTargetPlan(attempt,provider,movement,origin)
    end
    if type(attempt.destination)~='table' then return {kind='none',annotation={landing={kind='native'}}} end
    -- Any talent destination requires a source-pinned movement adapter: without
    -- it the plugin cannot map the requested request/landing to an audited native
    -- sequence. This is an execution-integrity capability gap, not a strategy
    -- refusal.
    if movement==nil then
        return nil,{reason='unsupported_movement_adapter',talent=attempt.talent,
            selector=attempt.destination.selector}
    end
    return M.planTalent(attempt.destination,provider,attempt.bound_target,movement,origin)
end

return M
