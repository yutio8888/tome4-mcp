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
-- Template mechanical invariants (target request kind, delivery, landing class,
-- centre, traversal, whether another actor is relocated) are **fixed** by the
-- named template and cannot be overridden by a caller. Only the per-talent
-- fields named as required/optional in the design §4.2 are parameterizable, and
-- nested getter/condition records are validated as closed objects.
--
-- Derived helpers live here because they belong to the same closed model:
--
--   * `M.resolveVariant(movement, talent, reads)` evaluates a state variant
--     matrix (for example Phase Door's effective-level x `phase_door_force_precise`
--     matrix) and returns exactly one descriptor. The declared `axes` are read
--     first, so an unknown attribute at TL4+ is still `movement_variant_unknown`
--     instead of a branch that never attempted the read. Zero, multiple or an
--     indeterminate branch also returns `movement_variant_unknown`; a known but
--     unimplemented branch returns its declared typed runtime reason (for
--     example `unsupported_target_plan`).
--   * `M.resolveBounds(movement, talent, reads)` resolves an audited dynamic
--     getter (`{getter='getRange'}`) into a finite number. An unavailable or
--     non-finite getter returns `movement_derivation_unknown`.
--   * `M.resolveBuilder(movement, talent, reads)` calls the pinned target
--     builder for **live geometry/conformance only** and copies an allowlisted
--     subset (shape/range/radius). It never infers actor/grid semantics or
--     prompt order from the builder.
--   * `M.resolveOccupancy(movement, occupancy)` turns a player-known occupancy
--     read (`'empty'|'actor'|'unknown'`) into the admitted non-swap descriptor,
--     the typed S4 swap gap, or `movement_variant_unknown`.
--
-- None of these helpers calls an action entrypoint, moves an actor, or reads
-- hidden state. `reads` is injected: unit tests supply fixtures, the runtime
-- supplies audited native objects. A missing reader is a typed unknown, never a
-- pass.
local M={}

M.REASON_INVALID='movement_adapter_invalid'
M.REASON_VARIANT_UNKNOWN='movement_variant_unknown'
M.REASON_DERIVATION_UNKNOWN='movement_derivation_unknown'

M.TARGET_REQUESTS={none=true,actor=true,grid=true,self=true}
M.DELIVERIES={step=true,line_move=true,leap=true,teleport=true,scene_change=true}
M.LANDINGS={exact=true,bounded_alternatives=true,random=true,source_defined=true}
M.CENTERS={self=true,actor=true,requested_grid=true}

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end

-- A reader may report a replaced transitive helper. That is source drift, not a
-- mere missing value, so it must be surfaced as `adapter_source_drift`.
local function isDriftReason(why)
    return type(why)=='string' and (why:find('replaced',1,true)~=nil
        or why:find('drift',1,true)~=nil
        or why:find('unverified',1,true)~=nil)
end

local function copyArray(src)
    local out={}
    for i=1,#src do out[i]=src[i] end
    return out
end

local function shallowCopy(src)
    local out={}
    for key,value in pairs(src) do
        if type(value)=='table' then
            local inner={}
            for k,v in pairs(value) do inner[k]=v end
            out[key]=inner
        else
            out[key]=value
        end
    end
    return out
end

-- Validate an envelope bound: a finite non-negative number, or an audited
-- dynamic getter record `{getter='name', min=, max=}`. The record is closed:
-- no other key is accepted.
local function validBound(value)
    if finite(value) then return value>=0 end
    if type(value)~='table' then return false end
    for key in pairs(value) do
        if key~='getter' and key~='min' and key~='max' then return false end
    end
    if type(value.getter)~='string' or #value.getter==0 then return false end
    if value.min~=nil and not finite(value.min) then return false end
    if value.max~=nil and not finite(value.max) then return false end
    if value.min~=nil and value.max~=nil and value.min>value.max then return false end
    return true
end

local function checkEnum(value,set)
    return type(value)=='string' and set[value]==true
end

-- A closed list is a dense `1..n` integer-keyed array. Non-integer keys and holes
-- are rejected instead of being silently ignored by `#`/`ipairs`.
local function validateArray(list,minLen)
    if type(list)~='table' then return false,'not_array' end
    local maxKey=0
    local count=0
    for key in pairs(list) do
        if type(key)~='number' or key%1~=0 or key<1 then return false,'non_integer_key' end
        if key>maxKey then maxKey=key end
        count=count+1
    end
    if minLen and maxKey<minLen then return false,'too_short' end
    if count~=maxKey then return false,'hole' end
    for i=1,maxKey do
        if list[i]==nil then return false,'hole' end
    end
    return true,maxKey
end

M.validateArray=validateArray

-- Discriminant-closed condition records: each kind allows only the fields it
-- actually consumes. A field belonging to another kind is rejected rather than
-- silently ignored.
local WHEN_KIND_KEYS={
    always={kind=true},
    all={kind=true,conditions=true},
    any={kind=true,conditions=true},
    talent_level={kind=true,at_least=true,below=true},
    attr={kind=true,id=true,truthy=true},
}
local function validateWhen(when,depth)
    depth=depth or 0
    if type(when)~='table' or type(when.kind)~='string' then return false,'bad_condition' end
    if depth>4 then return false,'condition_too_deep' end
    local allowed=WHEN_KIND_KEYS[when.kind]
    if not allowed then return false,'unknown_condition_kind' end
    for key in pairs(when) do
        if not allowed[key] then return false,'invalid_condition_field' end
    end
    if when.kind=='always' then
        return true
    elseif when.kind=='all' or when.kind=='any' then
        local arrayOk=validateArray(when.conditions,1)
        if not arrayOk then return false,'bad_condition_list' end
        for _,child in ipairs(when.conditions) do
            local nextOk,why=validateWhen(child,depth+1)
            if not nextOk then return false,why end
        end
        return true
    elseif when.kind=='talent_level' then
        if when.at_least==nil and when.below==nil then return false,'missing_level_bound' end
        if when.at_least~=nil and not finite(when.at_least) then return false,'bad_level_bound' end
        if when.below~=nil and not finite(when.below) then return false,'bad_level_bound' end
        return true
    elseif when.kind=='attr' then
        if type(when.id)~='string' or #when.id==0 then return false,'missing_attr_id' end
        if when.truthy~=nil and type(when.truthy)~='boolean' then return false,'bad_truthy' end
        return true
    end
    return false,'unknown_condition_kind'
end

M.validateWhen=validateWhen

-- Template declarations. `required` are per-talent review outputs that cannot
-- be derived; `optional` are the remaining per-talent fields; `fixed` are the
-- mechanical invariants of the named category and are rejected as parameters.
-- No template scans the game.
local TEMPLATES={
    -- Actor charge (for example Rush): a line move that stops before the bound
    -- actor. The landing is a bounded set of legal line cells.
    actor_charge={
        required={landing_proof=true},
        optional={builder_shape=true},
        fixed={target_requests={'actor'},delivery='line_move',
            landing='bounded_alternatives',center='actor',traverses=true,
            relocates_other=false},
    },
    -- Grid move to exactly the requested cell (Tumble, Vault). `delivery` and
    -- `traverses` are always per-talent (Tumble crosses, Vault vaults over);
    -- the landing class/centre and the non-relocation invariant are fixed.
    grid_move_exact={
        required={delivery=true,traverses=true},
        optional={landing_proof=true,builder_shape=true,range=true},
        fixed={target_requests={'grid'},landing='exact',
            center='requested_grid',relocates_other=false},
    },
    -- Grid request whose landing is a bounded native choice in a finite envelope
    -- (Blink, Dimensional Step non-swap, Phase Door precise grid). A finite
    -- radius (or audited getter) and its helper proof are mandatory.
    grid_move_bounded={
        required={delivery=true,traverses=true,radius=true,landing_proof=true},
        optional={min_radius=true,range=true,builder_shape=true,
            fallback_center=true,fallback_radius=true,fallback_when=true,
            occupancy_dependent=true},
        defaults={min_radius=0},
        fixed={target_requests={'grid'},landing='bounded_alternatives',
            center='requested_grid',relocates_other=false},
    },
    -- No-prompt self teleport (Phase Door below effective TL4 without the precise
    -- attribute). The landing envelope is a finite radius from an audited getter.
    self_random_teleport={
        required={radius=true,landing_proof=true},
        optional={min_radius=true,range=true},
        defaults={min_radius=0},
        fixed={target_requests={'none'},delivery='teleport',landing='random',
            center='self',traverses=false,relocates_other=false},
    },
    -- Actor-anchored self teleport (Shadowstep). The mover is the caster; the
    -- landing is a bounded native choice around the bound actor.
    actor_anchor_teleport={
        required={radius=true,landing_proof=true},
        optional={min_radius=true,range=true},
        defaults={min_radius=0},
        fixed={target_requests={'actor'},delivery='teleport',
            landing='bounded_alternatives',center='actor',traverses=false,
            relocates_other=false},
    },
}

M.TEMPLATES=TEMPLATES

-- Expand one template + parameters into a `movement` descriptor, or a typed
-- `movement_adapter_invalid`. Pure; rejects unknown templates/keys, attempts to
-- override a fixed invariant, and malformed values so a bad declaration can
-- never reach the planner.
function M.expand(template,params)
    local spec=TEMPLATES[template]
    if not spec or type(spec)~='table' or spec.fixed==nil then
        return nil,{reason=M.REASON_INVALID,detail='unknown_template',template=tostring(template)}
    end
    if type(params)~='table' then
        return nil,{reason=M.REASON_INVALID,detail='params_not_table',template=template}
    end
    for key in pairs(params) do
        if spec.fixed[key]~=nil then
            return nil,{reason=M.REASON_INVALID,detail='fixed_field',template=template,key=tostring(key)}
        end
        if not (spec.required[key] or spec.optional[key]) then
            return nil,{reason=M.REASON_INVALID,detail='unknown_key',template=template,key=tostring(key)}
        end
    end
    for key in pairs(spec.required) do
        if params[key]==nil then
            return nil,{reason=M.REASON_INVALID,detail='missing_required',template=template,key=key}
        end
    end
    local out={}
    for key,value in pairs(spec.fixed) do
        if key=='target_requests' then out.target_requests=copyArray(value) else out[key]=value end
    end
    for key,value in pairs(spec.defaults or {}) do
        if out[key]==nil then out[key]=value end
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
    if not checkEnum(out.center,M.CENTERS) then
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
    if type(out.traverses)~='boolean' then
        return nil,{reason=M.REASON_INVALID,detail='bad_traverses',template=template}
    end
    if type(out.relocates_other)~='boolean' then
        return nil,{reason=M.REASON_INVALID,detail='bad_relocates_other',template=template}
    end
    if out.builder_shape~=nil and (type(out.builder_shape)~='string' or #out.builder_shape==0) then
        return nil,{reason=M.REASON_INVALID,detail='bad_builder_shape',template=template}
    end
    if out.occupancy_dependent~=nil and type(out.occupancy_dependent)~='boolean' then
        return nil,{reason=M.REASON_INVALID,detail='bad_occupancy_dependent',template=template}
    end
    return out
end

-- Asserting wrapper used by the manifest: a declaration is static data, so a
-- malformed expansion must fail loudly at load instead of silently becoming a
-- `nil` entry.
function M.expandOrError(template,params)
    local movement,err=M.expand(template,params)
    if not movement then
        error('movement adapter expansion failed: '..tostring(template)..' '..
            tostring(err and err.detail),2)
    end
    return movement
end

-- Build a closed variant matrix from ordered `{when=..., template=..., params=...}`
-- or `{when=..., unsupported=...}` declarations. `axes` are condition records
-- that are always resolved before any branch is selected, so an unknown axis is
-- `movement_variant_unknown` even when no branch would test it.
function M.matrix(branches,axes)
    local branchesOk=validateArray(branches,1)
    if not branchesOk then
        return nil,{reason=M.REASON_INVALID,detail='bad_branches'}
    end
    if axes~=nil then
        local axesOk=validateArray(axes,1)
        if not axesOk then
            return nil,{reason=M.REASON_INVALID,detail='bad_axes'}
        end
        for _,axis in ipairs(axes) do
            local ok,why=validateWhen(axis)
            if not ok then return nil,{reason=M.REASON_INVALID,detail='bad_axis:'..tostring(why)} end
        end
    end
    local out={variants={},axes=axes}
    for index,branch in ipairs(branches) do
        if type(branch)~='table' or type(branch.when)~='table' then
            return nil,{reason=M.REASON_INVALID,detail='bad_variant_when',index=index}
        end
        for key in pairs(branch) do
            if key~='when' and key~='template' and key~='params' and key~='unsupported' then
                return nil,{reason=M.REASON_INVALID,detail='unknown_branch_field',index=index,key=tostring(key)}
            end
        end
        local ok,why=validateWhen(branch.when)
        if not ok then
            return nil,{reason=M.REASON_INVALID,detail='bad_variant_condition:'..tostring(why),index=index}
        end
        local variant={when=branch.when}
        if branch.unsupported~=nil then
            -- A known, source-reviewed branch whose execution capability does
            -- not exist in this slice (for example Phase Door TL4+ actor-then-
            -- grid before the ordered prompt queue). It is a typed capability
            -- gap, not a malformed adapter, and never a strategy refusal. The
            -- `typed_reason` is the reason the live/dry-run controller consumes
            -- (for example `unsupported_target_plan`).
            local unsupported=branch.unsupported
            if type(unsupported)~='table' or type(unsupported.missing)~='string'
                or type(unsupported.reason)~='string' then
                return nil,{reason=M.REASON_INVALID,detail='bad_variant_unsupported',index=index}
            end
            for key in pairs(unsupported) do
                if key~='scope' and key~='missing' and key~='reason'
                    and key~='typed_reason' and key~='requests' then
                    return nil,{reason=M.REASON_INVALID,detail='unknown_unsupported_field',
                        index=index,key=tostring(key)}
                end
            end
            if unsupported.typed_reason~=nil and type(unsupported.typed_reason)~='string' then
                return nil,{reason=M.REASON_INVALID,detail='bad_variant_typed_reason',index=index}
            end
            if unsupported.requests~=nil then
                if not validateArray(unsupported.requests,1) then
                    return nil,{reason=M.REASON_INVALID,detail='bad_variant_requests',index=index}
                end
                for _,requests in ipairs(unsupported.requests) do
                    if not validateArray(requests,1) then
                        return nil,{reason=M.REASON_INVALID,detail='bad_variant_requests',index=index}
                    end
                    for _,request in ipairs(requests) do
                        if not M.TARGET_REQUESTS[request] then
                            return nil,{reason=M.REASON_INVALID,detail='bad_variant_request_kind',index=index}
                        end
                    end
                end
            end
            variant.unsupported={scope=unsupported.scope or 'any',
                missing=unsupported.missing,reason=unsupported.reason,
                typed_reason=unsupported.typed_reason,
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
-- movement is returned unchanged. Declared axes are read first; an unknown axis
-- is `movement_variant_unknown`. Zero, multiple or indeterminate branches also
-- return `movement_variant_unknown`; a known unimplemented branch returns its
-- declared typed reason. There is no ordering fallback.
function M.resolveVariant(movement,talent,reads)
    if type(movement)~='table' or movement.variants==nil then return movement end
    reads=reads or {}
    for _,axis in ipairs(movement.axes or {}) do
        local value=evalWhen(axis,talent,reads)
        if value==nil then
            return nil,{reason=M.REASON_VARIANT_UNKNOWN,condition=axis,axis=true}
        end
    end
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
        return nil,{reason=unsupported.typed_reason or 'unsupported_movement_variant',
            scope=unsupported.scope,missing=unsupported.missing,
            reason_text=unsupported.reason}
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
            local ok,resolved,why=pcall(reads.talentGetter,talent,value.getter)
            if not ok or not finite(resolved) then
                if isDriftReason(why) then
                    return nil,{reason='adapter_source_drift',detail=why,getter=value.getter}
                end
                return nil,{reason=M.REASON_DERIVATION_UNKNOWN,dependency=value.getter,detail=why}
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

-- Call the pinned target builder for live geometry/conformance only. When the
-- descriptor declares a `builder_shape`, the builder is mandatory; a replaced
-- shape is `adapter_source_drift`. The returned `range`/`radius` are copied; the
-- builder never changes the curated request kind, centre, landing or prompt
-- order.
function M.resolveBuilder(movement,talent,reads)
    if type(movement)~='table' or movement.builder_shape==nil then return movement end
    reads=reads or {}
    if type(reads.builder)~='function' then
        return nil,{reason=M.REASON_DERIVATION_UNKNOWN,dependency='t.target'}
    end
    local ok,geometry,why=pcall(reads.builder,talent)
    if not ok or type(geometry)~='table' then
        if isDriftReason(why) then
            return nil,{reason='adapter_source_drift',detail=why}
        end
        return nil,{reason=M.REASON_DERIVATION_UNKNOWN,dependency='t.target',detail=why}
    end
    if geometry.shape~=movement.builder_shape then
        return nil,{reason='adapter_source_drift',detail='builder_shape',
            expected=movement.builder_shape,got=geometry.shape}
    end
    -- A builder-backed grid descriptor must expose a finite range: without it the
    -- planner cannot bound the target domain.
    if not finite(geometry.range) or geometry.range<0 then
        return nil,{reason=M.REASON_DERIVATION_UNKNOWN,dependency='t.target.range'}
    end
    local out=shallowCopy(movement)
    out.range=geometry.range
    out.builder_geometry={shape=geometry.shape,range=geometry.range,radius=geometry.radius}
    return out
end

-- Turn a player-known occupancy read into the admitted non-swap descriptor, the
-- typed S4 swap gap, or a typed unknown. `occupancy` is 'empty'|'actor'|'unknown';
-- the caller obtains it from player-known observation only.
function M.resolveOccupancy(movement,occupancy)
    if type(movement)~='table' or movement.occupancy_dependent~=true then return movement end
    if occupancy=='empty' then
        local out=shallowCopy(movement)
        out.relocates_other=false
        out.occupancy='empty'
        return out
    end
    if occupancy=='actor' then
        return nil,{reason='unsupported_movement_variant',scope='effective_talent_level>=5',
            missing='moving_or_swapping_another_actor',
            reason_text='the requested grid is known occupied; typed two-subject swap is not implemented'}
    end
    return nil,{reason=M.REASON_VARIANT_UNKNOWN,detail='occupancy_unknown'}
end

return M
