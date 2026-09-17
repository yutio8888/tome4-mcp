-- GPL-3.0-or-later. Closed movement-adapter factory + variant/bounds resolver (S1).
--
-- The factory is a *pure, closed* builder for the existing `movement` leaf
-- descriptor. It turns a small, source-reviewed template plus per-talent
-- parameters into the same descriptor the planner already consumes, so every
-- admitted talent stops hand-writing the same field shape. It is deliberately
-- **not** a talent scanner: it never inspects `is_teleport`, a cursor shape, a
-- talent name or the live game. Every admitted talent keeps an explicit entry in
-- `EffectManifest`; the factory only removes the repeated Lua boilerplate and
-- makes the audit boundary explicit.
--
-- Two derived helpers live here because they belong to the same closed model:
--
--   * `M.resolveVariant(movement, talent, reads)` evaluates a state variant
--     matrix (for example Phase Door's effective-level x `phase_door_force_precise`
--     matrix) and returns exactly one descriptor. Zero, multiple or an
--     indeterminate condition returns `movement_variant_unknown`; there is no
--     ordering fallback.
--   * `M.resolveBounds(movement, talent, reads)` resolves an audited dynamic
--     getter (`{getter='getRange'}`) into a finite number. An unavailable or
--     non-finite getter returns `movement_derivation_unknown`.
--
-- Neither helper calls an action entrypoint, moves an actor, or reads hidden
-- state. `reads` is injected: unit tests supply fixtures, the runtime supplies
-- audited native getters. A missing reader is a typed unknown, never a pass.
local M={}

M.REASON_INVALID='movement_adapter_invalid'
M.REASON_VARIANT_UNKNOWN='movement_variant_unknown'
M.REASON_DERIVATION_UNKNOWN='movement_derivation_unknown'

M.TARGET_REQUESTS={none=true,actor=true,grid=true,self=true}
M.DELIVERIES={step=true,line_move=true,leap=true,teleport=true,scene_change=true}
M.LANDINGS={exact=true,bounded_alternatives=true,random=true,source_defined=true}
M.CENTERS={self=true,actor=true,requested_grid=true}

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end

local function copyArray(src)
    local out={}
    for i=1,#src do out[i]=src[i] end
    return out
end

-- Validate an envelope bound: a finite non-negative number, or an audited
-- dynamic getter table `{getter='name', min=, max=}`. The getter is resolved at
-- plan time by `resolveBounds`; the factory only checks the declaration shape.
local function validBound(value)
    if finite(value) then return value>=0 end
    if type(value)=='table' and type(value.getter)=='string' and #value.getter>0 then
        if value.min~=nil and not finite(value.min) then return false end
        if value.max~=nil and not finite(value.max) then return false end
        return true
    end
    return false
end

local function checkEnum(value,set)
    return type(value)=='string' and set[value]==true
end

-- Template declarations. `defaults` are mechanical field shapes proven by the
-- template category; `required` fields are the per-talent review output that
-- cannot be derived; `allowed` is the closed key set (anything else is a
-- malformed adapter). No template scans the game.
local TEMPLATES={
    -- Actor charge (for example Rush): a line move that stops before the bound
    -- actor. The landing is a bounded set of legal line cells, so `landing_proof`
    -- is mandatory.
    actor_charge={
        required={landing_proof=true},
        allowed={landing_proof=true,delivery=true,center=true,traverses=true,
            relocates_other=true,range=true,radius=true},
        defaults={target_requests={'actor'},delivery='line_move',
            landing='bounded_alternatives',center='actor',traverses=true,
            relocates_other=false},
    },
    -- Grid move to exactly the requested cell (Tumble, Vault). `traverses` is
    -- always per-talent (Tumble crosses, Vault vaults over).
    grid_move_exact={
        required={delivery=true,traverses=true},
        allowed={delivery=true,traverses=true,center=true,relocates_other=true,
            range=true,landing_proof=true},
        defaults={target_requests={'grid'},landing='exact',
            center='requested_grid',relocates_other=false},
    },
    -- Grid request whose landing is a bounded native choice in a finite envelope
    -- (Blink, Dimensional Step non-swap, Phase Door precise grid). A finite
    -- radius (or audited getter) and its helper proof are mandatory.
    grid_move_bounded={
        required={delivery=true,traverses=true,radius=true,landing_proof=true},
        allowed={delivery=true,traverses=true,radius=true,min_radius=true,
            center=true,relocates_other=true,range=true,landing_proof=true,
            fallback_center=true,fallback_radius=true,fallback_when=true},
        defaults={target_requests={'grid'},landing='bounded_alternatives',
            center='requested_grid',relocates_other=false,min_radius=0},
    },
    -- No-prompt self teleport (Phase Door below effective TL4 without the precise
    -- attribute). The landing envelope is a finite radius from an audited getter.
    self_random_teleport={
        required={radius=true,landing_proof=true},
        allowed={radius=true,min_radius=true,range=true,landing_proof=true},
        defaults={target_requests={'none'},delivery='teleport',landing='random',
            center='self',traverses=false,relocates_other=false,min_radius=0},
    },
    -- Actor-anchored self teleport (Shadowstep). The mover is the caster; the
    -- landing is a bounded native choice around the bound actor.
    actor_anchor_teleport={
        required={radius=true,landing_proof=true},
        allowed={radius=true,min_radius=true,range=true,landing_proof=true,
            traverses=true,relocates_other=true,center=true},
        defaults={target_requests={'actor'},delivery='teleport',
            landing='bounded_alternatives',center='actor',traverses=false,
            relocates_other=false,min_radius=0},
    },
}

M.TEMPLATES=TEMPLATES

-- Expand one template + parameters into a `movement` descriptor, or a typed
-- `movement_adapter_invalid`. Pure; rejects unknown templates/keys and malformed
-- values so a bad declaration can never reach the planner.
function M.expand(template,params)
    local spec=TEMPLATES[template]
    if not spec then
        return nil,{reason=M.REASON_INVALID,detail='unknown_template',template=tostring(template)}
    end
    if type(params)~='table' then
        return nil,{reason=M.REASON_INVALID,detail='params_not_table',template=template}
    end
    for key in pairs(spec.required) do
        if params[key]==nil then
            return nil,{reason=M.REASON_INVALID,detail='missing_required',template=template,key=key}
        end
    end
    for key in pairs(params) do
        if not spec.allowed[key] then
            return nil,{reason=M.REASON_INVALID,detail='unknown_key',template=template,key=tostring(key)}
        end
    end
    local out={}
    for key,value in pairs(spec.defaults) do
        if key=='target_requests' then out.target_requests=copyArray(value) else out[key]=value end
    end
    for key,value in pairs(params) do
        if key=='target_requests' then out.target_requests=copyArray(value) else out[key]=value end
    end
    if not checkEnum(out.delivery,M.DELIVERIES) then
        return nil,{reason=M.REASON_INVALID,detail='bad_delivery',template=template,value=out.delivery}
    end
    if not checkEnum(out.landing,M.LANDINGS) then
        return nil,{reason=M.REASON_INVALID,detail='bad_landing',template=template,value=out.landing}
    end
    if out.center~=nil and not checkEnum(out.center,M.CENTERS) then
        return nil,{reason=M.REASON_INVALID,detail='bad_center',template=template,value=out.center}
    end
    if out.min_radius~=nil and not validBound(out.min_radius) then
        return nil,{reason=M.REASON_INVALID,detail='bad_min_radius',template=template}
    end
    if out.range~=nil and not validBound(out.range) then
        return nil,{reason=M.REASON_INVALID,detail='bad_range',template=template}
    end
    if out.radius~=nil and not validBound(out.radius) then
        return nil,{reason=M.REASON_INVALID,detail='bad_radius',template=template}
    end
    if out.fallback_radius~=nil and not validBound(out.fallback_radius) then
        return nil,{reason=M.REASON_INVALID,detail='bad_fallback_radius',template=template}
    end
    if out.fallback_center~=nil and not checkEnum(out.fallback_center,M.CENTERS) then
        return nil,{reason=M.REASON_INVALID,detail='bad_fallback_center',template=template}
    end
    if out.traverses~=nil and type(out.traverses)~='boolean' then
        return nil,{reason=M.REASON_INVALID,detail='bad_traverses',template=template}
    end
    if out.relocates_other~=nil and type(out.relocates_other)~='boolean' then
        return nil,{reason=M.REASON_INVALID,detail='bad_relocates_other',template=template}
    end
    return out
end

-- Build a closed variant matrix from ordered `{when=..., template=..., params=...}`
-- declarations. Each branch is a fully expanded descriptor; the resolver picks
-- exactly one at plan time. A malformed branch fails the whole declaration.
function M.matrix(branches)
    if type(branches)~='table' or #branches==0 then
        return nil,{reason=M.REASON_INVALID,detail='empty_matrix'}
    end
    local out={variants={}}
    for index,branch in ipairs(branches) do
        if type(branch)~='table' or type(branch.when)~='table' then
            return nil,{reason=M.REASON_INVALID,detail='bad_variant_when',index=index}
        end
        local variant={when=branch.when}
        if branch.unsupported~=nil then
            -- A known, source-reviewed branch whose execution capability does
            -- not exist in this slice (for example Phase Door TL4+ actor-then-
            -- grid before the ordered prompt queue). It is a typed capability
            -- gap, not a malformed adapter, and never a strategy refusal.
            local unsupported=branch.unsupported
            if type(unsupported)~='table' or type(unsupported.missing)~='string'
                or type(unsupported.reason)~='string' then
                return nil,{reason=M.REASON_INVALID,detail='bad_variant_unsupported',index=index}
            end
            variant.unsupported={scope=unsupported.scope or 'any',
                missing=unsupported.missing,reason=unsupported.reason,
                requests=unsupported.requests}
        else
            local movement,err=M.expand(branch.template,branch.params or {})
            if not movement then
                err=err or {}
                err.index=index
                return nil,err
            end
            variant.movement=movement
        end
        out.variants[#out.variants+1]=variant
    end
    return out
end

-- Evaluate one declarative variant condition. Returns true/false or nil for an
-- indeterminate read. Only `talent_level`, `attr` and boolean `all`/`any` are
-- allowed; an unknown condition is indeterminate (fail closed).
local function evalWhen(when,talent,reads)
    reads=reads or {}
    if type(when)~='table' or when.kind==nil then return nil end
    if when.kind=='always' then return true end
    if when.kind=='all' then
        if type(when.conditions)~='table' then return nil end
        for _,child in ipairs(when.conditions) do
            local value=evalWhen(child,talent,reads)
            if value~=true then return value end
        end
        return true
    end
    if when.kind=='any' then
        if type(when.conditions)~='table' then return nil end
        local unknown=false
        for _,child in ipairs(when.conditions) do
            local value=evalWhen(child,talent,reads)
            if value==true then return true end
            if value==nil then unknown=true end
        end
        if unknown then return nil end
        return false
    end
    if when.kind=='talent_level' then
        if type(reads.talentLevel)~='function' then return nil end
        local ok,level=pcall(reads.talentLevel,talent)
        if not ok or not finite(level) then return nil end
        if when.at_least~=nil then return level>=when.at_least end
        if when.below~=nil then return level<when.below end
        return nil
    end
    if when.kind=='attr' then
        if type(reads.attr)~='function' then return nil end
        local ok,value,known=pcall(reads.attr,when.id)
        if not ok then return nil end
        -- `known` may be omitted by a test reader; require an explicit true so a
        -- failed/absent read is distinguishable. A successful read may return
        -- nil/false/0 (definitely absent).
        if known~=true then return nil end
        local truthy=value~=nil and value~=false and value~=0
        if when.truthy==false then return not truthy end
        return truthy
    end
    return nil
end

M.evalWhen=evalWhen

-- Resolve a state-variant matrix to exactly one descriptor. A non-variant
-- movement is returned unchanged. Zero, multiple or indeterminate matches return
-- a typed `movement_variant_unknown`; there is no ordering fallback. The returned
-- descriptor is a fresh table (the caller may attach resolved bounds).
function M.resolveVariant(movement,talent,reads)
    if type(movement)~='table' or movement.variants==nil then return movement end
    local matched
    for _,variant in ipairs(movement.variants) do
        local value=evalWhen(variant.when,talent,reads)
        if value==nil then
            return nil,{reason=M.REASON_VARIANT_UNKNOWN,condition=variant.when}
        end
        if value==true then
            if matched~=nil then
                return nil,{reason=M.REASON_VARIANT_UNKNOWN,detail='multiple_matches',
                    condition=variant.when}
            end
            matched=variant
        end
    end
    if matched==nil then
        return nil,{reason=M.REASON_VARIANT_UNKNOWN,detail='no_match'}
    end
    if matched.unsupported~=nil then
        local unsupported=matched.unsupported
        return nil,{reason='unsupported_movement_variant',scope=unsupported.scope,
            missing=unsupported.missing,reason_text=unsupported.reason}
    end
    local descriptor=matched.movement
    local out={}
    for key,value in pairs(descriptor) do
        if key=='target_requests' then out.target_requests=copyArray(value) else out[key]=value end
    end
    return out
end

-- Resolve every dynamic envelope bound (`{getter='name'}`) through the injected,
-- audited reader. An unavailable or non-finite value is a typed
-- `movement_derivation_unknown`, never a fabricated constant.
function M.resolveBounds(movement,talent,reads)
    if type(movement)~='table' then return movement end
    reads=reads or {}
    local out={}
    for key,value in pairs(movement) do
        if type(value)=='table' and type(value.getter)=='string' then
            if type(reads.talentGetter)~='function' then
                return nil,{reason=M.REASON_DERIVATION_UNKNOWN,dependency=value.getter}
            end
            local ok,resolved=pcall(reads.talentGetter,talent,value.getter)
            if not ok or not finite(resolved) then
                return nil,{reason=M.REASON_DERIVATION_UNKNOWN,dependency=value.getter}
            end
            if value.min~=nil and resolved<value.min then resolved=value.min end
            if value.max~=nil and resolved>value.max then resolved=value.max end
            if resolved<0 then resolved=0 end
            out[key]=resolved
        else
            out[key]=value
        end
    end
    return out
end

return M
