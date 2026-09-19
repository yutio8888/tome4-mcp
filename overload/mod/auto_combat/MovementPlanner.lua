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
local Json=require 'mod.mcp_bridge.Json'
local Factory=require 'mod.auto_combat.MovementAdapterFactory'
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

-- P2-1 fallback contract: when a deterministic landing was settled as a native
-- rejection, the controller re-plans the same selector/anchor with that
-- coordinate excluded, so the deterministic tie-break can pick the next
-- acceptable alternative. `exclude` is a set keyed by "x,y"; it is a
-- correctness (never-resubmit) filter, not a strategy restriction. A
-- non-deterministic native landing has no single coordinate and is never
-- excluded (Rush/teleport behavior is untouched).
local function excluded(set,x,y)
    return set~=nil and set[x..','..y]==true
end

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
function M.planStep(request,provider,bound,origin,exclude)
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
        if annotation.in_bounds and not excluded(exclude,x,y) then
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

-- Resolve an occupancy-dependent adapter at one requested grid from
-- player-known information only. `provider.occupancy(x,y)` returns
-- 'empty'|'actor'|'unknown'; a hidden cell is 'unknown' and never probed.
local function resolveOccupancyAt(movement,provider,x,y)
    if type(movement)~='table' or movement.occupancy_dependent~=true then return movement end
    local occupancy=provider.occupancy and provider.occupancy(x,y) or nil
    return Factory.resolveOccupancy(movement,occupancy)
end

-- Plan a talent destination. `movement` is the manifest's movement adapter (or
-- nil, which is a capability gap for the native-landing selectors).
-- S2-REV-02: apply the declared landing envelope (kind/radius/min_radius and
-- the LOS-fallback branch) to a resolved candidate cell's annotation, so
-- `destination.accept.landing` sees the TRUE native landing shape. Every
-- selector that can lower to a `request_then_landing` step must call this
-- BEFORE policy acceptance: a `bounded_alternatives`/`random` adapter does not
-- land on the scanned cell, so a deterministic annotation would misreport a
-- random landing. `exact` (a single source-proven landing) stays
-- deterministic; a random landing stays an ANNOTATION the policy decides on,
-- never a plugin refusal.
local function applyLandingEnvelope(annotation,movement,origin,x,y)
    if type(movement)~='table' or movement.landing=='exact' or movement.landing==nil then
        return annotation
    end
    local landing={kind=movement.landing=='random' and 'random' or 'bounded',
        center={x=x,y=y}}
    if finite(movement.radius) then landing.radius=movement.radius end
    if finite(movement.min_radius) then landing.min_radius=movement.min_radius end
    if movement.fallback_center then
        local fcenter=movement.fallback_center=='self' and {x=origin.x,y=origin.y} or {x=x,y=y}
        landing.fallback={kind='random',center=fcenter}
        if finite(movement.fallback_radius) then landing.fallback.radius=movement.fallback_radius end
        annotation.reasons[#annotation.reasons+1]='los_fallback_envelope'
    end
    annotation.landing=landing
    annotation.confidence='source_'..tostring(movement.landing)
    annotation.reasons[#annotation.reasons+1]='native_random_landing'
    annotation.reasons[#annotation.reasons+1]='hidden_occupancy_not_inspected'
    return annotation
end

function M.planTalent(request,provider,bound,movement,origin,exclude)
    origin=origin or (provider.origin and provider.origin())
    if not origin then return nil,{reason='origin_unavailable'} end
    movement=movement or {}
    if request.selector and not M.TALENT_SELECTORS[request.selector] then
        return nil,{reason='unsupported_selector_for_talent',selector=request.selector}
    end
    -- An occupancy-dependent adapter (Dimensional Step TL5) can only be resolved
    -- for an explicit or scanned grid, never for a landing the native code picks
    -- without exposing its coordinate.
    if movement.occupancy_dependent and request.selector~='position' and request.selector~='relative'
        and request.selector~='toward' and request.selector~='away'
        and request.selector~='preferred_distance' then
        return nil,{reason='movement_variant_unknown',detail='occupancy_requires_grid',
            selector=request.selector}
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
        -- MAF-REV-03: the live native range bounds the request domain. A forced
        -- coordinate outside it would be rejected by `Actions` and fall back to
        -- the interactive prompt, so the planner rejects it here.
        if finite(movement.range) and Distance.grid(origin.x,origin.y,x,y)>movement.range then
            return nil,{reason='destination_out_of_range',x=x,y=y,range=movement.range,
                distance=Distance.grid(origin.x,origin.y,x,y)}
        end
        -- An occupancy-dependent adapter (Dimensional Step TL5) must resolve the
        -- mover from player-known information at the requested grid before any
        -- native request is built. A known actor is the typed S4 gap; unknown
        -- occupancy fails closed; no hidden actor is inspected.
        local occMovement,occErr=resolveOccupancyAt(movement,provider,x,y)
        if not occMovement then return nil,occErr end
        movement=occMovement
        local annotation=M.annotate(x,y,provider)
        if annotation.in_bounds==false then
            return nil,{reason='destination_out_of_bounds',x=x,y=y,annotation=annotation}
        end
        -- S2-REV-02: the annotation must report the declared envelope before
        -- policy acceptance. `exact` stays deterministic.
        annotation.selector=request.selector
        annotation=applyLandingEnvelope(annotation,movement,origin,x,y)
        local ok,reason=M.accepts(request.accept,annotation)
        if not ok then return nil,{reason=reason,annotation=annotation} end
        -- A previously natively-rejected exact grid request is never
        -- resubmitted for this selector/anchor; the caller falls through honestly.
        if excluded(exclude,x,y) then
            return nil,{reason='no_acceptable_destination',selector=request.selector,x=x,y=y}
        end
        annotation.reasons[#annotation.reasons+1]='native_builder_validates_request'
        return {kind='grid',x=x,y=y,annotation=annotation}
    end
    -- toward/away/preferred_distance: bounded scan around the origin, in y,x
    -- order, annotated from player-known info and filtered only by `accept`.
    local anchor=anchorFor(request,provider,bound,origin)
    if not anchor then return nil,{reason='anchor_unavailable',selector=request.selector} end
    -- The live cursor range bounds the candidate enumeration. Without a resolved
    -- finite range the planner must not invent one: scanning a hard-coded radius
    -- can select a coordinate the native talent cannot target. A plain `move`
    -- step does not reach here (it uses the adjacent keypad set).
    if not finite(movement.range) then
        return nil,{reason='movement_range_unknown',selector=request.selector}
    end
    local radius=math.floor(movement.range)
    -- MAF-REV-03: range 0 is an empty non-self target domain, not a forced radius
    -- of one. Candidate enumeration also filters by the single audited native
    -- distance metric, not the square [-r,+r] bounding box.
    if radius<0 then radius=0 end
    if radius>M.SCAN_RADIUS then radius=M.SCAN_RADIUS end
    local best
    local occupancy_uncertain=false
    local occupancy_actor=false
    for dy=-radius,radius do
        for dx=-radius,radius do
            if not (dx==0 and dy==0) then
                local x,y=origin.x+dx,origin.y+dy
                local candidate_ok=Distance.grid(origin.x,origin.y,x,y)<=radius
                if movement.occupancy_dependent then
                    local occ=provider.occupancy and provider.occupancy(x,y) or nil
                    if occ=='empty' then
                        -- Keep the range filter already applied above.
                    elseif occ=='actor' then candidate_ok=false; occupancy_actor=true
                    else candidate_ok=false; occupancy_uncertain=true end
                end
                local annotation=M.annotate(x,y,provider)
                -- S2-REV-02: the envelope is applied BEFORE acceptance so the
                -- policy decides on the true native landing shape; a
                -- deterministic policy rejects a random landing on its own
                -- terms and the candidate is simply not selected.
                annotation=applyLandingEnvelope(annotation,movement,origin,x,y)
                if candidate_ok and annotation.in_bounds and not excluded(exclude,x,y) then
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
    if not best then
        if movement.occupancy_dependent then
            if occupancy_uncertain then
                return nil,{reason='movement_variant_unknown',detail='occupancy_unknown',
                    selector=request.selector}
            end
            if occupancy_actor then
                return nil,{reason='unsupported_movement_variant',scope='effective_talent_level>=5',
                    missing='moving_or_swapping_another_actor',
                    reason_text='every in-range requested grid is known occupied; typed two-subject swap is not implemented'}
            end
        end
        return nil,{reason='no_acceptable_destination',selector=request.selector}
    end
    best.annotation.selector=request.selector
    best.annotation.reasons[#best.annotation.reasons+1]='native_builder_validates_request'
    return {kind='grid',x=best.x,y=best.y,annotation=best.annotation,score=best.score}
end

-- Build the annotation for a no-explicit-endpoint native request (self/actor
-- landing derived by native code) from the manifest's movement classification.
-- S2-REV-02: the LOS-fallback branch is part of the declared envelope, so it
-- is reported here too (the sequence per-step annotations share this builder).
local function nativeLandingAnnotation(movement,anchor,origin)
    movement=movement or {}
    if movement.landing=='random' then
        local bounds={kind='random',source='native'}
        if finite(movement.radius) then bounds.radius=movement.radius end
        if finite(movement.min_radius) then bounds.min_radius=movement.min_radius end
        if finite(movement.range) then bounds.range=movement.range end
        if movement.fallback_center then
            local fcenter=(movement.fallback_center=='self' and type(origin)=='table')
                and {x=origin.x,y=origin.y}
                or (type(anchor)=='table' and {x=anchor.x,y=anchor.y} or nil)
            if fcenter then
                bounds.fallback={kind='random',center=fcenter}
                if finite(movement.fallback_radius) then bounds.fallback.radius=movement.fallback_radius end
            end
        end
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

-- A source-pinned adapter may declare state variants (for example Phase Door's
-- effective-level x `phase_door_force_precise` matrix). Resolve exactly one
-- descriptor through the closed factory; an unknown/ambiguous condition is a
-- typed `movement_variant_unknown` and never falls back to a leaf. A known but
-- unimplemented branch (TL4+ actor-then-grid before the ordered prompt queue) is
-- published as the typed capability reason the factory supplied (for Phase Door
-- that is `unsupported_target_plan`, which both controllers pause on).
local function resolveMovement(movement,provider,talent)
    if movement==nil then return nil end
    local reads={talentLevel=provider.talentLevel,attr=provider.attr,
        talentGetter=provider.talentGetter,builder=provider.builder}
    local resolved,err=Factory.resolveVariant(movement,talent,reads)
    if not resolved then return nil,err end
    local bounds,boundErr=Factory.resolveBounds(resolved,talent,reads)
    if not bounds then return nil,boundErr end
    -- Live target geometry: the actual builder (called directly, no identity
    -- gate) supplies only an allowlisted shape/range/radius. It never changes
    -- the curated request kind, centre, landing or prompt order.
    local built,buildErr=Factory.resolveBuilder(bounds,talent,reads)
    if not built then return nil,buildErr end
    return built
end


-- Plan one entry of an ordered `request_then_landing` program (S2 §2.5). Each
-- entry is planned by the *existing* kind-specific branch, so range bounding,
-- occupancy resolution, envelope annotation and `accept` evaluation are reused
-- verbatim; the entry additionally carries the decided value the executor's
-- queue will answer that native prompt with. `value` is a closed internal
-- descriptor consumed only by the executor (`Actions.lua`), never by policy.
local function planSequenceEntry(entry,step,attempt,provider,movement,origin)
    -- The accept object is the step's own `destination.accept` when present; the
    -- action-level destination is the fallback for entries that declare none (a
    -- policy may reasonably put the accept object on the landing step only).
    local accept=(type(step.destination)=='table') and step.destination.accept or nil
    if accept==nil and type(attempt.destination)=='table' then accept=attempt.destination.accept end
    -- S2-REV-04: a program entry is a real native prompt (`actor`/`grid`/`self`);
    -- the factory rejects `none` at declaration time, and a direct planner call
    -- with one fails closed here instead of lowering an unexecutable entry.
    if entry.request~='actor' and entry.request~='grid' and entry.request~='self' then
        return nil,{reason='movement_adapter_invalid',detail='bad_request_kind',
            request=tostring(entry.request)}
    end
    if entry.request=='grid' then
        -- A grid prompt is answered either from the step's own policy target
        -- (`value_source='target_plan'`) or, when the descriptor curates
        -- `value_source='subject'`, from the subject's cell. The declared value
        -- source is honoured; it is never inferred from the native cursor spec.
        if entry.value_source=='subject' then
            local anchor
            if entry.subject=='self' then
                anchor={x=origin.x,y=origin.y}
            else
                anchor=provider.anchor and provider.anchor('bound_target',attempt.bound_target) or nil
            end
            if not anchor then
                return nil,{reason='movement_request_value_unknown',
                    dependency=entry.subject=='self' and 'self' or 'bound_actor'}
            end
            local annotation=nativeLandingAnnotation(movement,anchor,origin)
            local ok,reason=M.accepts(accept or {visibility='any',passability='native',
                hazard='any',landing='allow_random'},annotation)
            if not ok then return nil,{reason=reason,annotation=annotation} end
            local value={kind='grid',request='grid',x=anchor.x,y=anchor.y}
            if entry.optional==true then value.optional=true end
            return {kind='grid',x=anchor.x,y=anchor.y,annotation=annotation,value=value}
        end
        if type(step.destination)~='table' then
            return nil,{reason='movement_request_value_unknown',index=nil,
                dependency='target_plan.destination'}
        end
        local planned,err=M.planTalent(step.destination,provider,attempt.bound_target,
            movement,origin,attempt.exclude)
        if not planned then return nil,err end
        planned.value={kind='grid',request='grid',x=planned.x,y=planned.y}
        if entry.optional==true then planned.value.optional=true end
        return planned
    end
    if entry.request=='self' then
        local annotation=nativeLandingAnnotation(movement,{x=origin.x,y=origin.y},origin)
        annotation.landing.kind=(movement.landing=='exact' or movement.landing==nil)
            and 'deterministic' or annotation.landing.kind
        annotation.confidence='self_request'
        annotation.reasons={'self_request','landing_is_origin'}
        local ok,reason=M.accepts(accept or {visibility='any',passability='native',
            hazard='any',landing='allow_random'},annotation)
        if not ok then return nil,{reason=reason,annotation=annotation} end
        local value={kind='self',request='self'}
        if entry.optional==true then value.optional=true end
        return {kind='self',annotation=annotation,value=value}
    end
    -- actor
    local stepSelector=step.selector
    local actionSelector=attempt.target
    if stepSelector~=nil and actionSelector~=nil and stepSelector~=actionSelector then
        return nil,{reason='target_plan_selector_mismatch',talent=attempt.talent,
            expected=actionSelector,got=stepSelector}
    end
    local effective=stepSelector or actionSelector
    -- The descriptor's `subject` is the curated binding of the answer. A
    -- self-subject prompt must be answered with the caster; a policy that binds
    -- another actor moves that actor, which the single-subject descriptor cannot
    -- verify (the S4 `moving_or_swapping_another_actor` gap). This is a
    -- capability reason, never a strategy refusal.
    if entry.subject=='self' and effective~=nil and effective~='self' then
        return nil,{reason='unsupported_movement_variant',scope='subject_other_than_self',
            missing='moving_or_swapping_another_actor',
            reason_text='the descriptor binds this prompt to the caster; relocating another actor needs the typed two-subject descriptor (S4)'}
    end
    local anchor
    local value
    if entry.subject=='self' then
        anchor=provider.anchor and provider.anchor('self') or nil
        value={kind='self',request='actor'}
    else
        anchor=provider.anchor and provider.anchor('bound_target',attempt.bound_target) or nil
        value={kind='actor',request='actor',target_id=attempt.bound_target}
        if attempt.bound_target==nil then
            return nil,{reason='movement_request_value_unknown',index=nil,
                dependency='bound_actor'}
        end
    end
    if not anchor then
        return nil,{reason='anchor_unavailable',selector=effective or 'bound_target'}
    end
    local annotation=nativeLandingAnnotation(movement,anchor,origin)
    local ok,reason=M.accepts(accept or {visibility='any',passability='native',
        hazard='any',landing='allow_random'},annotation)
    if not ok then return nil,{reason=reason,annotation=annotation} end
    if entry.optional==true then value.optional=true end
    return {kind='actor',annotation=annotation,value=value}
end

-- Build a `{kind='sequence'}` plan for an ordered `request_then_landing`
-- program: one planned step per declared entry, in order, each carrying the
-- decided value the executor answers that native prompt with. The landing
-- annotation is the last entry's (the landing step), augmented with the declared
-- request kinds and the per-step request annotation; the policy's `accept` object
-- is evaluated per entry, so a random/out-of-vision landing stays an annotation
-- and only the policy's decision can refuse it.
function M.planSequence(attempt,provider,movement,origin)
    local sequence=movement.request_sequence
    local plan=attempt.target_plan
    local sequenceOk,sequenceCount=Json.denseArray(sequence,1)
    local planOk,planCount=Json.denseArray(plan,1)
    if not sequenceOk or not planOk then return nil,{reason='invalid_target_plan'} end
    if planCount<1 then return nil,{reason='invalid_target_plan'} end
    if planCount~=sequenceCount then
        -- The descriptor declares an ordered program, so a plan that disagrees in
        -- length/kind is a policy/adapter mismatch (the static validator already
        -- rejects it; this is the planner's own honest defence).
        return nil,{reason='target_plan_mismatch',talent=attempt.talent,
            expected=sequenceCount,got=planCount}
    end
    for i=1,sequenceCount do
        if plan[i].request~=sequence[i].request then
            return nil,{reason='target_plan_mismatch',talent=attempt.talent,
                expected=Factory.requestKinds(sequence)[i],got=plan[i].request,index=i}
        end
    end
    local steps={}
    local values={}
    for i=1,sequenceCount do
        local entry=sequence[i]
        local planned,err=planSequenceEntry(entry,plan[i],attempt,provider,movement,origin)
        if not planned then
            if err and err.reason=='movement_request_value_unknown' then err.index=i end
            return nil,err
        end
        steps[i]=planned
        values[i]=planned.value
        -- S2 rev3: carry the curated observed signature with the decided value, so
        -- the executor matches the live prompt against the same curation the
        -- factory validated for this position (`action.sequence[i].observed`).
        if values[i]~=nil and entry.observed~=nil then values[i].observed=entry.observed end
    end
    local landing=steps[#steps].annotation
    local kinds={}
    for i=1,sequenceCount do kinds[i]=sequence[i].request end
    local annotation={}
    for key,value in pairs(landing) do annotation[key]=value end
    annotation.requests=kinds
    annotation.sequence=kinds
    annotation.reasons=annotation.reasons or {}
    annotation.reasons[#annotation.reasons+1]='ordered_prompt_sequence'
    return {kind='sequence',steps=steps,values=values,
        request_sequence=sequence,annotation=annotation}
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
        return M.planTalent(step.destination,provider,attempt.bound_target,movement,origin,attempt.exclude)
    end
    if request=='none' then
        local annotation=nativeLandingAnnotation(movement,nil,origin)
        local _,err=acceptAnnotation(annotation,{visibility='any',passability='native',
            hazard='any',landing='allow_random'})
        if err then return nil,err end
        return {kind='none',annotation=annotation}
    end
    if request=='self' then
        local annotation=nativeLandingAnnotation(movement,{x=origin.x,y=origin.y},origin)
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
        -- MFT-REV-03 (Option A): an actor step selector is the declared binding
        -- when the action has no selector. A contradiction with an explicit
        -- action binding is non-determinability, never silently resolved.
        local stepSelector=step.selector
        local actionSelector=attempt.target
        if stepSelector~=nil and actionSelector~=nil and stepSelector~=actionSelector then
            return nil,{reason='target_plan_selector_mismatch',talent=attempt.talent,
                expected=actionSelector,got=stepSelector}
        end
        local effective=stepSelector or actionSelector
        local anchor
        if effective=='self' then
            anchor=provider.anchor and provider.anchor('self') or nil
        else
            anchor=provider.anchor and provider.anchor('bound_target',attempt.bound_target) or nil
        end
        if not anchor then
            return nil,{reason='anchor_unavailable',selector=effective or 'bound_target'}
        end
        local annotation=nativeLandingAnnotation(movement,anchor,origin)
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
        return M.planStep(attempt.destination,provider,attempt.bound_target,origin,attempt.exclude)
    end
    local variantErr
    if movement~=nil then
        -- MAF-REV-06 (no-strict-audit): planning calls the live adapter directly;
        -- there is no identity/digest/closure preflight gate. An unobtainable
        -- value simply fails the derivation (movement_derivation_unknown) or the
        -- variant (movement_variant_unknown) below.
        movement,variantErr=resolveMovement(movement,provider,attempt.talent)
        if variantErr then
            -- Propagate the typed reason unchanged; the caller publishes the same
            -- typed capability/variant reason. An unknown condition stays fail
            -- closed (`movement_variant_unknown`); a known unimplemented branch
            -- is its declared typed reason (`unsupported_target_plan` for the
            -- Phase Door actor+grid branch, which both controllers pause on).
            return nil,variantErr
        end
    end
    if type(attempt.target_plan)=='table' then
        -- S2 §12.1: a descriptor that declares an ordered `request_sequence` is
        -- driven by the queue for every N (including N=1: a self-subject actor
        -- prompt cannot be expressed by the single-target lowering, which would
        -- otherwise reject with `target_lost`). Only an un-upgraded multi-prompt
        -- adapter keeps the typed capability pause (never a silent ignore).
        -- Checklist A: `attempt.target_plan` is caller data, so both `#` reads
        -- below go through the dense/closed validator first; a malformed plan is
        -- the ordinary typed `invalid_target_plan`, never a shorter "multi_prompt"
        -- measurement taken from a truncated `#`.
        local planDense,planCount=Json.denseArray(attempt.target_plan,1)
        if not planDense then
            return nil,{reason='invalid_target_plan',talent=attempt.talent}
        end
        local sequenceDense,sequenceCount=false,nil
        if type(movement)=='table' and type(movement.request_sequence)=='table' then
            -- Present but malformed -> fail closed, never fall back to a
            -- smaller single-request interpretation (checklist C).
            sequenceDense,sequenceCount=Json.denseArray(movement.request_sequence,1)
            if not sequenceDense then
                return nil,{reason='invalid_target_plan',talent=attempt.talent,
                    detail='movement_request_sequence_not_dense'}
            end
        end
        if sequenceDense and sequenceCount>0 then
            return M.planSequence(attempt,provider,movement,origin)
        end
        if planCount>1 then
            return nil,{reason='unsupported_target_plan',talent=attempt.talent,
                count=planCount,scope='multi_prompt',
                missing='ordered_request_sequence'}
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
    return M.planTalent(attempt.destination,provider,attempt.bound_target,movement,origin,attempt.exclude)
end

return M
