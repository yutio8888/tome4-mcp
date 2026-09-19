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
-- S2 (`request_then_landing`): the binding of one ordered prompt's answer and
-- the source of its decided value. Both are closed vocabularies.
M.REQUEST_SUBJECTS={self=true,actor=true}
M.REQUEST_VALUE_SOURCES={subject=true,target_plan=true}
M.DELIVERIES={step=true,line_move=true,leap=true,teleport=true,scene_change=true}
M.LANDINGS={exact=true,bounded_alternatives=true,random=true,source_defined=true}
M.CENTERS={self=true,actor=true,requested_grid=true}

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end

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

-- S2-REV-03: a declared `target_requests` is a closed dense `1..n` array. The
-- legacy `copyArray` silently truncated holes/non-array/unknown keys to length
-- 1, so a malformed declaration was accepted and its length/kind cross-check
-- against `request_sequence` bypassed. Validate BEFORE copying; any malformed
-- form is `movement_adapter_invalid` at build time.
local function copyTargetRequests(src)
    local ok,countOrCause=validateArray(src,1)
    if not ok then return nil,{detail='bad_target_requests',cause=countOrCause} end
    local out={}
    for i=1,countOrCause do out[i]=src[i] end
    return out
end

-- Normalise and validate one `request_sequence` (S2 §4.4). The record is closed:
-- `index` must equal the array position (a hole/gap/reorder is invalid), the
-- prompt kind and subject binding come from the closed vocabularies, `optional`
-- is only admitted on the trailing entry, `landing_from` is only 'envelope', and
-- `observed` is the per-entry **curated observed signature** (S2 rev3): the
-- closed allowlist of static discriminators the reviewed flow raises at this
-- position. A published sequence must carry a signature on every entry; for
-- N≥2 no entry's signature may SUBSUME another's (presence-explicit match
-- semantics; see `signatureSubsumes`), else the subsumed entry can never be
-- uniquely matched and the descriptor is
-- `movement_adapter_invalid`/`request_signature_ambiguous`.
-- Returns a fresh array of normalised entries (no shared reference with the
-- caller's declaration).
local SEQUENCE_KEYS={index=true,request=true,subject=true,value_source=true,
    landing_from=true,optional=true,observed=true}
-- The closed `observed` signature allowlist: `cursor_type` plus the static
-- discriminators. Dynamic numerics (`range`/`radius`) and closures are never
-- signature fields.
local OBSERVED_SIGNATURE_KEYS={cursor_type=true,default_target=true,first_target=true,
    msg=true,nolock=true,pass_terrain=true,friendlyblock=true,nowarning=true,
    immediate_keys=true,no_restrict=true}
local OBSERVED_SIGNATURE_FLAGS={nolock=true,pass_terrain=true,friendlyblock=true,
    nowarning=true,immediate_keys=true,no_restrict=true}
local OBSERVED_SIGNATURE_STRINGS={first_target=64,msg=512}
local function normalizeObserved(observed,index)
    if type(observed)~='table' then return nil,{detail='bad_observed_signature',index=index} end
    for key in pairs(observed) do
        if not OBSERVED_SIGNATURE_KEYS[key] then
            return nil,{detail='unknown_observed_key',index=index,key=tostring(key)}
        end
    end
    if type(observed.cursor_type)~='string' or #observed.cursor_type==0
        or #observed.cursor_type>32 then
        return nil,{detail='bad_observed_cursor_type',index=index}
    end
    local copy={cursor_type=observed.cursor_type}
    for flag in pairs(OBSERVED_SIGNATURE_FLAGS) do
        if observed[flag]~=nil then
            if type(observed[flag])~='boolean' then
                return nil,{detail='bad_observed_flag',index=index,key=flag}
            end
            copy[flag]=observed[flag]
        end
    end
    for key,limit in pairs(OBSERVED_SIGNATURE_STRINGS) do
        if observed[key]~=nil then
            if type(observed[key])~='string' or #observed[key]>limit then
                return nil,{detail='bad_observed_string',index=index,key=key}
            end
            copy[key]=observed[key]
        end
    end
    if observed.default_target~=nil then
        if observed.default_target~='self' then
            return nil,{detail='bad_observed_default_target',index=index}
        end
        copy.default_target='self'
    end
    return copy
end
-- S2-R3-01 rev5 (presence-explicit semantics, normative). A curated observed
-- signature is a record of the allowlisted static discriminators the reviewed
-- native flow raises at this position; matching is PRESENCE-EXPLICIT, not
-- wildcard-based:
--   * `cursor_type` is always declared and constrains `typ.type` by equality;
--   * a declared boolean flag must be PRESENT in the observed spec and EQUAL
--     (so `{cursor_type='hit'}` is distinguishable from
--     `{cursor_type='hit',nolock=true}`, and a declared `nolock=false` is a real
--     constraint distinct from absence — Vault's two prompts differ exactly by
--     nolock presence);
--   * a declared string (`first_target`/`msg`) or `default_target='self'` must
--     be present and equal when the signature declares it; when the signature
--     OMITS them, the observed spec's value is ignored — real flows raise them
--     nondeterministically (Phase Door's `first_target` is rng.percent-driven,
--     conveyance.lua:85), so they are never required-absent;
--   * an observed spec may not raise an allowlisted field the entry does not
--     declare beyond the string/default_target exception above (no wildcard).
-- The build-time ambiguity rule (decidable by inspection): for every pair of
-- entries in an N≥2 sequence, one signature must not SUBSUME the other — i.e.
-- one entry's match set must not contain the other's (equal flag constraint
-- sets and the subsumer declaring no additional strings). A subsumed entry can
-- never be the unique match of any prompt, so the descriptor is
-- `movement_adapter_invalid`/`request_signature_ambiguous`. The normative
-- runtime safety net is the executor's EXACTLY-ONE rule (`Actions.lua`): a
-- raised prompt may be answered only when exactly one declared entry — the
-- arrival position — matches it; zero matches, several matches, or a match at
-- another index are typed deviations that pause and hand the live prompt back.
local function signatureSubsumes(a,b)
    -- b's match set ⊆ a's: the flag constraint sets must be IDENTICAL (a
    -- declared flag is present-and-equal, an undeclared one required-absent, so
    -- any flag difference makes the sets disjoint, not nested), and every
    -- string/default_target a declares must also be declared by b with the same
    -- value.
    if a.cursor_type~=b.cursor_type then return false end
    for flag in pairs(OBSERVED_SIGNATURE_FLAGS) do
        if (a[flag]~=nil)~=(b[flag]~=nil) then return false end
        if a[flag]~=nil and a[flag]~=b[flag] then return false end
    end
    for key in pairs(OBSERVED_SIGNATURE_STRINGS) do
        if a[key]~=nil and (b[key]==nil or b[key]~=a[key]) then return false end
    end
    if a.default_target~=nil and (b.default_target==nil or b.default_target~=a.default_target) then
        return false
    end
    return true
end
function M.normalizeRequestSequence(list)
    local ok,maxKey=validateArray(list,1)
    if not ok then return nil,{detail='request_sequence_not_array'} end
    if maxKey>8 then return nil,{detail='request_sequence_too_long'} end
    local out={}
    for i=1,maxKey do
        local entry=list[i]
        if type(entry)~='table' then return nil,{detail='bad_request_entry',index=i} end
        for key in pairs(entry) do
            if not SEQUENCE_KEYS[key] then
                return nil,{detail='unknown_request_key',index=i,key=tostring(key)}
            end
        end
        if entry.index~=i then return nil,{detail='request_index_mismatch',index=i} end
        if not M.TARGET_REQUESTS[entry.request] then
            return nil,{detail='bad_request_kind',index=i}
        end
        -- S2-REV-04: a sequence entry is a real native prompt. `none` (no
        -- prompt at all) stays a `target_requests` value for single-request
        -- descriptors such as `self_random_teleport`; as a program entry it
        -- would be accepted at build time and then fail executor lowering
        -- (`invalid_sequence`), so it is rejected here at declaration time.
        if entry.request=='none' then
            return nil,{detail='bad_request_kind',index=i,reason_text='none is not a native prompt; it cannot form an ordered program'}
        end
        if not M.REQUEST_SUBJECTS[entry.subject] then
            return nil,{detail='bad_subject',index=i}
        end
        local valueSource=entry.value_source or 'subject'
        if not M.REQUEST_VALUE_SOURCES[valueSource] then
            return nil,{detail='bad_value_source',index=i}
        end
        if entry.landing_from~=nil and entry.landing_from~='envelope' then
            return nil,{detail='bad_landing_from',index=i}
        end
        if entry.optional~=nil and type(entry.optional)~='boolean' then
            return nil,{detail='bad_optional',index=i}
        end
        if entry.optional==true and i~=maxKey then
            return nil,{detail='optional_not_trailing',index=i}
        end
        -- S2 rev3: every published sequence entry carries a curated observed
        -- signature (the runtime evidence the executor matches).
        local observed,observedErr=normalizeObserved(entry.observed,i)
        if not observed then return nil,observedErr end
        local copy={index=i,request=entry.request,subject=entry.subject,
            value_source=valueSource,observed=observed}
        if entry.landing_from~=nil then copy.landing_from=entry.landing_from end
        if entry.optional==true then copy.optional=true end
        out[i]=copy
    end
    -- S2-R3-01 rev5: for N≥2 no entry's curated signature may SUBSUME another's
    -- (presence-explicit match semantics; see `signatureSubsumes`): a subsumed
    -- entry can never be the unique match of any raised prompt, so the
    -- descriptor is refused at build time (a plugin-completeness boundary,
    -- never a strategy judgement). Pairs that are merely distinguishable under
    -- presence semantics (Vault's hit-without-nolock vs hit+nolock) are
    -- admitted; the runtime EXACTLY-ONE gate is the normative safety net.
    if maxKey>=2 then
        for i=1,maxKey-1 do
            for j=i+1,maxKey do
                if signatureSubsumes(out[i].observed,out[j].observed)
                    or signatureSubsumes(out[j].observed,out[i].observed) then
                    return nil,{detail='request_signature_ambiguous',
                        indexes={i,j},signature=out[i].observed.cursor_type}
                end
            end
        end
    end
    return out
end

-- The declared prompt kinds of one normalised sequence.
function M.requestKinds(sequence)
    local out={}
    for i=1,#sequence do out[i]=sequence[i].request end
    return out
end

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
    -- Ordered prompt-response program (S2 §4.4): the executor answers the k-th
    -- native `getTarget` with the k-th declared entry's decided value inside one
    -- action opportunity and one native submission. There are **no** mechanical
    -- defaults for the request order, subject binding, centre, bounds or landing:
    -- every value is a per-talent source-review output, and the sequence plus
    -- every branch/envelope is curated. `target_requests` is derived from the
    -- sequence when omitted; when supplied it must agree in length and kind.
    request_then_landing={
        required={request_sequence=true,delivery=true,landing=true,center=true,
            traverses=true,relocates_other=true},
        optional={target_requests=true,radius=true,min_radius=true,range=true,
            builder_shape=true,fallback_center=true,fallback_radius=true,
            fallback_when=true,occupancy_dependent=true,landing_proof=true},
        fixed={},
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
        if key=='target_requests' then out.target_requests=value else out[key]=value end
    end
    for key,value in pairs(spec.defaults or {}) do
        if out[key]==nil then out[key]=value end
    end
    for key,value in pairs(params) do
        if key=='target_requests' then out.target_requests=value else out[key]=value end
    end
    -- S2-REV-03: a declared `target_requests` (fixed or caller-supplied) must be
    -- a closed dense `1..n` array; a hole, non-array or unknown key is
    -- `movement_adapter_invalid` at build time instead of being silently
    -- truncated by `#`.
    if out.target_requests~=nil then
        local requests,reqErr=copyTargetRequests(out.target_requests)
        if not requests then
            local err={reason=M.REASON_INVALID,template=template}
            for key,value in pairs(reqErr) do err[key]=value end
            return nil,err
        end
        out.target_requests=requests
    end
    -- S2: a `request_sequence` is normalised and cross-checked against the
    -- static capability list. A hole, gap, reorder, bad kind/subject/value
    -- source, non-trailing `optional`, unknown key or a `target_requests`
    -- disagreement is `movement_adapter_invalid` (never silently ignored).
    if out.request_sequence~=nil then
        local sequence,seqErr=M.normalizeRequestSequence(out.request_sequence)
        if not sequence then
            local err={reason=M.REASON_INVALID,template=template}
            for key,value in pairs(seqErr) do err[key]=value end
            return nil,err
        end
        local kinds=M.requestKinds(sequence)
        if out.target_requests~=nil then
            if #out.target_requests~=#kinds then
                return nil,{reason=M.REASON_INVALID,
                    detail='request_sequence_length_mismatch',template=template}
            end
            for i=1,#kinds do
                if out.target_requests[i]~=kinds[i] then
                    return nil,{reason=M.REASON_INVALID,
                        detail='request_sequence_kind_mismatch',template=template,index=i}
                end
            end
        end
        out.request_sequence=sequence
        out.target_requests=kinds
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
        -- `at_least` and `below` may be declared together (a bounded cell of the
        -- variant matrix, for example Phase Door's effective TL4 cell in [4,5)).
        -- The effective level is read once; the declared bounds are then applied
        -- to that single value so a replaced getter cannot disagree with itself.
        if when.at_least==nil and when.below==nil then return nil end
        if when.at_least~=nil and level<when.at_least then return false end
        if when.below~=nil and level>=when.below then return false end
        return true
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
        if key=='target_requests' then
            -- Curated dense list; copy 1..# defensively (build-time validation
            -- happens in `M.expand`).
            local requests={}
            for i=1,#value do requests[i]=value[i] end
            out.target_requests=requests
        elseif key=='request_sequence' then
            local sequence={}
            for i=1,#value do
                local entry={}
                for k,v in pairs(value[i]) do
                    if k=='observed' and type(v)=='table' then
                        local sig={}
                        for sk,sv in pairs(v) do sig[sk]=sv end
                        entry.observed=sig
                    else entry[k]=v end
                end
                sequence[i]=entry
            end
            out.request_sequence=sequence
        else out[key]=value end
    end
    return out
end

-- Resolve every dynamic envelope bound (`{getter='name'}`) through the injected
-- reader. An unavailable or non-finite value is a typed
-- `movement_derivation_unknown`, never a fabricated constant. There is no
-- identity gate: the game's actual getter is used as a normal entrypoint.
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

-- Call the target builder for live geometry/conformance only. When the
-- descriptor declares a `builder_shape`, a non-conformant shape means the
-- geometry is not obtainable (`movement_derivation_unknown`); there is no
-- identity gate. The returned `range`/`radius` are copied; the builder never
-- changes the curated request kind, centre, landing or prompt order.
function M.resolveBuilder(movement,talent,reads)
    if type(movement)~='table' or movement.builder_shape==nil then return movement end
    reads=reads or {}
    if type(reads.builder)~='function' then
        return nil,{reason=M.REASON_DERIVATION_UNKNOWN,dependency='t.target'}
    end
    local ok,geometry,why=pcall(reads.builder,talent)
    if not ok or type(geometry)~='table' then
        return nil,{reason=M.REASON_DERIVATION_UNKNOWN,dependency='t.target',detail=why}
    end
    if geometry.shape~=movement.builder_shape then
        return nil,{reason=M.REASON_DERIVATION_UNKNOWN,dependency='t.target.shape',
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

M.AUDITED_SHAPES={hit=true,ball=true,beam=true,bolt=true,widebeam=true,cone=true}

-- S3 closed mixed-entry composition (design §5.1/§6.1). A published mixed entry
-- is a closed record with exactly these declaration keys (`source` is attached
-- after construction and is generated/advisory metadata, not a declaration key).
M.COMPOSITION_KEYS={kind=true,target=true,resource=true,movement=true,components=true,
    movement_postcondition=true,conformance=true}
-- Each component is a closed record with these keys only.
M.COMPONENT_KEYS={id=true,phase=true,delivery=true,shape=true,center=true,range=true,
    radius=true,angle=true,direction=true,selffire=true,friendlyfire=true,
    player_selffire=true,when=true,provenance=true,duration=true,per_grid=true}
M.COMPONENT_PHASES={melee=true,instant=true,projectile=true,secondary=true,ground=true}
M.COMPONENT_DELIVERIES={attackTarget=true,project=true,projectile=true,map_effect=true}
M.COMPONENT_CENTERS={target=true,actor=true,self=true,actual_landing=true}
-- A `center='actual_landing'` component is admitted only for the two shapes the
-- post-move cell can anchor (design §5.1).
M.ACTUAL_LANDING_SHAPES={hit=true,ball=true}
-- The projected (multi-actor) delivery path forwards the FULL
-- engine-consulted raised field set (S3-A2-R2 dispatcher correction): the seven
-- curated projection flags PLUS the fields ActorProject/Target consult that
-- can each change the footprint (`force_max_range`, `min_range`,
-- `grid_exclude`, `filter`, `block_path`, `block_radius`,
-- `requires_knowledge`, actor-delivery `act_exclude`). An explicit `false` is
-- preserved (it disables the default blocker, Target.lua:559-569);
-- function-valued `block_path`/`block_radius`/`filter` are forwarded as the
-- real callbacks. `AutoCombatGuard` forwards exactly this set — this table is
-- the single canonical list.
M.RAISED_FLAG_KEYS={friendlyblock=true,friendlyfire=true,selffire=true,
    pass_terrain=true,no_restrict=true,actorblock=true,stop_block=true,
    force_max_range=true,min_range=true,grid_exclude=true,filter=true,
    block_path=true,block_radius=true,requires_knowledge=true,
    act_exclude=true}
M.POSTCONDITION_MODES={fizzle=true,mismatch=true}

local function validStaticFilter(value)
    -- A curated static filter is a boolean, a finite percentage, the string
    -- 'unknown', or exactly the audited dynamic input record `{dynamic='...'}`.
    if type(value)=='boolean' then return true end
    if value=='unknown' then return true end
    if finite(value) then return value>=0 and value<=100 end
    if type(value)=='table' then
        local extra=0
        for key in pairs(value) do
            if key~='dynamic' then return false end
            extra=extra+1
        end
        return extra==1 and type(value.dynamic)=='string' and #value.dynamic>0
    end
    return false
end

local function validComponentRadius(value)
    if finite(value) then return value>=0 end
    if type(value)~='table' then return false end
    for key in pairs(value) do
        if key~='from' then return false end
    end
    return value.from=='target'
end

-- Validate one S3 component record. Returns true or `nil, cause`.
function M.validateComponent(component)
    if type(component)~='table' then return nil,{detail='component_not_table'} end
    for key in pairs(component) do
        if not M.COMPONENT_KEYS[key] then
            return nil,{detail='unknown_component_key',key=tostring(key)}
        end
    end
    if type(component.id)~='string' or #component.id==0 then
        return nil,{detail='bad_component_id'}
    end
    if not checkEnum(component.phase,M.COMPONENT_PHASES) then
        return nil,{detail='bad_component_phase',value=tostring(component.phase)}
    end
    if not checkEnum(component.delivery,M.COMPONENT_DELIVERIES) then
        return nil,{detail='bad_component_delivery',value=tostring(component.delivery)}
    end
    if type(component.shape)~='string' or not M.AUDITED_SHAPES[component.shape] then
        return nil,{detail='bad_component_shape',value=tostring(component.shape)}
    end
    if not checkEnum(component.center,M.COMPONENT_CENTERS) then
        return nil,{detail='bad_component_center',value=tostring(component.center)}
    end
    -- `actual_landing` is admitted only for the post-move-anchored shapes with a
    -- resolved radius, on the projection delivery, and never as a melee phase.
    if component.center=='actual_landing' then
        if not M.ACTUAL_LANDING_SHAPES[component.shape] then
            return nil,{detail='actual_landing_shape',value=component.shape}
        end
        if component.delivery~='project' then
            return nil,{detail='actual_landing_delivery',value=tostring(component.delivery)}
        end
        if component.phase=='melee' then
            return nil,{detail='actual_landing_melee'}
        end
        if not validComponentRadius(component.radius) then
            return nil,{detail='actual_landing_radius_missing'}
        end
    end
    if component.shape=='ball' and component.radius==nil then
        return nil,{detail='ball_radius_missing'}
    end
    if component.radius~=nil and not validComponentRadius(component.radius) then
        return nil,{detail='bad_component_radius'}
    end
    if component.angle~=nil and not finite(component.angle) then
        return nil,{detail='bad_component_angle'}
    end
    if component.range~=nil and not validBound(component.range) then
        return nil,{detail='bad_component_range'}
    end
    if component.direction~=nil and type(component.direction)~='string' then
        return nil,{detail='bad_component_direction'}
    end
    if component.when~=nil then
        if type(component.when)~='table' then return nil,{detail='bad_component_when'} end
        for key in pairs(component.when) do
            if key~='kind' and key~='anchor' then
                return nil,{detail='unknown_when_key',key=tostring(key)}
            end
        end
        if component.when.kind~='always' and component.when.kind~='landing_adjacent' then
            return nil,{detail='bad_when_kind',value=tostring(component.when.kind)}
        end
        if component.when.kind=='landing_adjacent' and component.when.anchor~='actor' then
            return nil,{detail='bad_when_anchor',value=tostring(component.when.anchor)}
        end
    end
    -- Direct bound-actor effects never run ActorProject, so the projection
    -- filters are meaningless on them (declaring one would imply a filter that
    -- does not exist); a projected effect must declare its filters explicitly.
    if component.delivery=='attackTarget' then
        if component.selffire~=nil or component.friendlyfire~=nil
            or component.player_selffire~=nil then
            return nil,{detail='direct_actor_forbids_projection_filters'}
        end
    elseif component.delivery=='project' then
        if not validStaticFilter(component.selffire) then
            return nil,{detail='projected_selffire_required'}
        end
        if not validStaticFilter(component.friendlyfire) then
            return nil,{detail='projected_friendlyfire_required'}
        end
        if type(component.provenance)~='table' then
            return nil,{detail='projected_provenance_required'}
        end
    end
    if component.duration~=nil and not finite(component.duration) then
        return nil,{detail='bad_component_duration'}
    end
    if component.per_grid~=nil and type(component.per_grid)~='boolean' then
        return nil,{detail='bad_component_per_grid'}
    end
    return true
end

-- Validate a whole mixed movement entry (closed declaration keys, dense
-- non-empty components, movement descriptor present, closed postcondition,
-- `conformance={builder=true|false}` only). Returns true or `nil, cause`.
function M.validateComposition(entry)
    if type(entry)~='table' then return nil,{detail='entry_not_table'} end
    for key in pairs(entry) do
        -- `source` is generated/advisory metadata attached after construction
        -- (never a declaration key), so it is ignored here.
        if key~='source' and not M.COMPOSITION_KEYS[key] then
            return nil,{detail='unknown_entry_key',key=tostring(key)}
        end
    end
    if entry.kind~='movement' then return nil,{detail='bad_kind',value=tostring(entry.kind)} end
    if entry.target~='hostile' then return nil,{detail='bad_target',value=tostring(entry.target)} end
    if type(entry.movement)~='table' then return nil,{detail='movement_missing'} end
    local ok,cause=validateArray(entry.components,1)
    if not ok then return nil,{detail='bad_components',cause=cause} end
    local ids={}
    for index,component in ipairs(entry.components) do
        local componentOk,why=M.validateComponent(component)
        if not componentOk then
            why=why or {}
            why.index=index
            why.component=component.id
            return nil,why
        end
        if ids[component.id] then
            return nil,{detail='duplicate_component_id',index=index,component=component.id}
        end
        ids[component.id]=true
    end
    local post=entry.movement_postcondition
    if type(post)~='table' then return nil,{detail='bad_postcondition'} end
    for key in pairs(post) do
        if key~='mover' and key~='endpoint' and key~='unchanged' then
            return nil,{detail='unknown_postcondition_key',key=tostring(key)}
        end
    end
    if post.mover~='self' then
        return nil,{detail='bad_postcondition_mover',value=tostring(post.mover)}
    end
    if post.endpoint~='landing_envelope' then
        return nil,{detail='bad_postcondition_endpoint',value=tostring(post.endpoint)}
    end
    if not M.POSTCONDITION_MODES[post.unchanged] then
        return nil,{detail='bad_postcondition_unchanged',value=tostring(post.unchanged)}
    end
    local conformance=entry.conformance
    if type(conformance)~='table' then return nil,{detail='bad_conformance'} end
    for key in pairs(conformance) do
        if key~='builder' then return nil,{detail='unknown_conformance_key',key=tostring(key)} end
    end
    if conformance.builder~=true and conformance.builder~=false then
        return nil,{detail='bad_conformance_builder',value=tostring(conformance.builder)}
    end
    return true
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
