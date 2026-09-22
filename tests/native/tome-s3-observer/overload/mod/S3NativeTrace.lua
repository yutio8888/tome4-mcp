-- GPL-3.0-or-later. TEST-ONLY passive observer for real native target requests
-- and their answers (S3 supplemental evidence harness).
--
-- Scope and honesty (TRACE-01..04, design feedback S3-EVIDENCE-01):
--   * This module is loaded ONLY by the explicit test addon
--     `tests/native/tome-s3-observer` (never by the production addon); it is
--     therefore never present in `dist/tome-mcp-bridge.teaa`.
--   * It OBSERVES the real `typ` a native action passes to `Actor:getTarget`
--     and the REAL values that current getter returns. It never synthesizes an
--     answer, never changes a `typ`/actor/command/plan, never calls `useTalent`
--     itself, never touches RNG, energy, cooldowns or control leases.
--   * It wraps the CURRENT `getTarget` (whatever the production bridge or any
--     other addon installed at action time) for the duration of one native
--     action, then restores the saved raw field. This is disclosed test
--     instrumentation; it is NOT a proof that the wrapped function is an
--     unmodified native implementation (AGENTS.md: no runtime identity gate).
--   * Emission is best effort. A failing emitter/sink must never change the
--     game result; the failure is counted and reported, and a missing record is
--     NEVER read as a native outcome.
--
-- The module has NO top-level game dependency: the pure mechanics below are
-- unit-testable offline (tests/test_s3_native_trace.lua) with controlled
-- functions. `install()` is the only game-aware entrypoint.

local M = {prefix = '[S3NativeTrace]'}

local function finite(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end
local function pack(...) return {n = select('#', ...), ...} end

-- Strict bounded JSON for the trace line. Deliberately self-contained (the
-- test addon must not require production modules) and closed: only finite
-- numbers, booleans, strings and dense string-keyed tables are encodable.
-- `false` is a VALUE and is always emitted as `false`; only `nil` is dropped.
local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return ('\\u%04x'):format(char:byte())
    end) .. '"'
end
function M.encode(value)
    local seen = {}
    local function emit(entry, depth)
        if depth > 16 then error('trace encode: too deep', 0) end
        if entry == nil then return 'null' end
        local kind = type(entry)
        if kind == 'string' then return quote(entry) end
        if kind == 'boolean' then return entry and 'true' or 'false' end
        if kind == 'number' then
            if not finite(entry) then error('trace encode: non-finite number', 0) end
            return (('%.17g'):format(entry):gsub(',', '.'))
        end
        if kind ~= 'table' then error('trace encode: unsupported ' .. kind, 0) end
        if seen[entry] then error('trace encode: cyclic table', 0) end
        seen[entry] = true
        local highest, count, keys = 0, 0, {}
        for key in pairs(entry) do
            count = count + 1
            if type(key) == 'number' and key >= 1 and key % 1 == 0 then
                highest = math.max(highest, key)
            elseif type(key) == 'string' then
                keys[#keys + 1] = key
            else
                error('trace encode: invalid key', 0)
            end
            if count > 64 then error('trace encode: too many keys', 0) end
        end
        local parts = {}
        if highest > 0 then
            if #keys > 0 or highest ~= count then error('trace encode: sparse array', 0) end
            for i = 1, count do parts[i] = emit(entry[i], depth + 1) end
            seen[entry] = nil
            return '[' .. table.concat(parts, ',') .. ']'
        end
        table.sort(keys)
        for _, key in ipairs(keys) do parts[#parts + 1] = quote(key) .. ':' .. emit(entry[key], depth + 1) end
        seen[entry] = nil
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return emit(value, 0)
end

function M.write(line) print(line) end

-- Raw `typ` facts. `nolock_present` separates ABSENT from explicit false; a
-- non-boolean `nolock` is reported by type instead of being coerced. Only
-- bounded scalars are recorded (no hidden entity enumeration).
function M.typFacts(typ)
    if type(typ) ~= 'table' then
        return {present = false, raw_type = type(typ)}
    end
    local present = typ.nolock ~= nil
    local facts = {present = true,
        type = type(typ.type) == 'string' and typ.type or nil,
        range = finite(typ.range) and typ.range or nil,
        radius = finite(typ.radius) and typ.radius or nil,
        nolock_present = present}
    if present and type(typ.nolock) == 'boolean' then facts.nolock = typ.nolock
    elseif present then facts.nolock_type = type(typ.nolock) end
    return facts
end

-- Bounded actor identity/position (player/target data only).
function M.actorFacts(actor)
    if type(actor) ~= 'table' then return {present = false} end
    return {present = true,
        x = finite(actor.x) and actor.x or nil,
        y = finite(actor.y) and actor.y or nil,
        uid = finite(actor.uid) and actor.uid or nil}
end

-- Answer facts from the packed return values of the observed getter. Arity is
-- recorded exactly; nil vs false is kept distinct; the returned actor UID is
-- recorded only when the third value is a table with a finite `uid`.
function M.answerFacts(results)
    local x, y, entity = results[1], results[2], results[3]
    local function classify(value)
        if value == nil then return nil, 'nil' end
        if value == false then return false, 'false' end
        if finite(value) then return value, 'number' end
        return nil, type(value)
    end
    local xv, xc = classify(x)
    local yv, yc = classify(y)
    local facts = {arity = results.n, x = xv, y = yv,
        x_class = xc, y_class = yc,
        has_actor = type(entity) == 'table' and true or false}
    if type(entity) == 'table' then
        facts.uid = finite(entity.uid) and entity.uid or nil
    else
        facts.actor_class = type(entity)
    end
    return facts
end

-- Observer/recorder. `writer` defaults to the native log sink; `collect`, when
-- a table, receives every emitted record (test inspection) BEFORE the write, so
-- a throwing sink is still observable.
function M.newObserver(options)
    options = options or {}
    return {
        writer = options.writer or M.write,
        collect = options.collect,
        max_requests = options.max_requests or 32,
        max_records = options.max_records or 256,
        invocation = 0,
        requests = 0,         -- lifetime total (bounded by max_requests)
        emitted = 0,
        truncated = false,
        emit_failures = false, -- boolean: at least one emission failed
    }
end

-- Best-effort bounded emission. Returns ok,err; never raises.
function M.emitRecord(observer, record)
    observer.emitted = observer.emitted + 1
    if observer.emitted > observer.max_records then
        observer.truncated = true
        return false, 'record_bound'
    end
    if observer.collect then observer.collect[#observer.collect + 1] = record end
    local ok, line = pcall(M.encode, record)
    if not ok then
        observer.emit_failures = true
        return false, line
    end
    local wrote, err = pcall(observer.writer, M.prefix .. ' ' .. line)
    if not wrote then
        observer.emit_failures = true
        return false, err
    end
    return true
end

-- Bounded, PROTECTED error text (COORD-HARN-04). A native error object may
-- carry a `__tostring` metamethod that itself throws; formatting it must never
-- replace the original error. Returns a bounded string, or the type name when
-- formatting is impossible.
function M.safeErrorText(value)
    local kind = type(value)
    if kind == 'string' then return value:sub(1, 512) end
    local ok, text = pcall(tostring, value)
    if ok and type(text) == 'string' then return text:sub(1, 512) end
    return kind
end

-- A delegate getter: calls the captured current getter EXACTLY ONCE with the
-- identical arguments, records the real request and the real answer, and
-- returns the ORIGINAL values with their exact arity. It does NOT use pcall, so
-- a native `coroutine.yield()` (the real targeting flow) passes straight
-- through, and an original error propagates unchanged with no fabricated
-- answer. No value is ever substituted.
--
-- COORD-HARN-03: the incoming vararg list is packed and forwarded verbatim, so
-- a call with only the actor (`getTarget(actor)`) still reaches the current
-- getter with arity 1 — not an injected extra `nil`.
--
-- `scope` is the INVOCATION-local counter (COORD-HARN-02): request ordinals are
-- 1..n within each invocation, independent of earlier invocations. The
-- observer-level `requests` total is kept separately as an explicit bound.
function M.observeGetter(observer, current, invocation, talent, actor, scope)
    scope = scope or {requests = 0}
    return function(...)
        local args = pack(...)
        observer.requests = observer.requests + 1
        scope.requests = scope.requests + 1
        local request = scope.requests
        local visible = observer.requests <= observer.max_requests
        if not visible then observer.truncated = true end
        if visible then
            M.emitRecord(observer, {kind = 'request', invocation = invocation, request = request,
                talent = talent, actor = M.actorFacts(actor or args[1]), typ = M.typFacts(args[2])})
        end
        local results = pack(current(unpack(args, 1, args.n)))
        if visible then
            M.emitRecord(observer, {kind = 'answer', invocation = invocation, request = request,
                talent = talent, answer = M.answerFacts(results)})
        end
        return unpack(results, 1, results.n)
    end
end

-- Wrap a talent action. It records one invocation, installs the delegate
-- getter around the CURRENT `actor.getTarget` for the duration of the action,
-- calls the captured original action EXACTLY ONCE, restores the saved raw field
-- (success, original error and — under a yieldable LuaJIT pcall — coroutine
-- yield/resume), then rethrows the ORIGINAL error object with `error(err,0)`.
--
-- COORD-HARN-03: the whole incoming argument list (including `self`) is packed
-- and forwarded verbatim, so the original action observes the SAME arity as the
-- caller supplied; no extra trailing `nil` is injected.
-- COORD-HARN-04: error formatting is protected (`M.safeErrorText`), so an error
-- object with a throwing `__tostring` is still rethrown unchanged.
function M.wrapAction(observer, original, talent)
    return function(...)
        local args = pack(...)
        local self = args[1]
        observer.invocation = observer.invocation + 1
        local invocation = observer.invocation
        local saved = rawget(self, 'getTarget')
        local current = self.getTarget
        local scope = {requests = 0}
        M.emitRecord(observer, {kind = 'invocation_start', invocation = invocation, talent = talent,
            actor = M.actorFacts(self), getter_present = type(current) == 'function',
            raw_field_present = saved ~= nil})
        local installed = false
        if type(current) == 'function' then
            rawset(self, 'getTarget', M.observeGetter(observer, current, invocation, talent, self, scope))
            installed = true
        end
        local results = pack(pcall(original, unpack(args, 1, args.n)))
        if installed then rawset(self, 'getTarget', saved) end
        local ok = results[1]
        M.emitRecord(observer, {kind = 'invocation_finish', invocation = invocation, talent = talent,
            ok = ok and true or false, error = (not ok) and M.safeErrorText(results[2]) or nil,
            requests = scope.requests, lifetime_requests = observer.requests,
            truncated = observer.truncated == true,
            emit_failures = observer.emit_failures == true})
        if not ok then error(results[2], 0) end
        return unpack(results, 2, results.n)
    end
end

-- Idempotent installation of the T_VAULT observer. Called from
-- `hooks/load.lua` on `ToME:load` (after `/data/talents.lua` defined the
-- talents). Returns a result record; a missing talent is reported, never
-- raised.
function M.install(options)
    if M.installed then return M.installed end
    local result
    local ok, ActorTalents = pcall(require, 'engine.interface.ActorTalents')
    local defs = ok and type(ActorTalents) == 'table' and ActorTalents.talents_def or nil
    local def = type(defs) == 'table' and defs.T_VAULT or nil
    if type(def) ~= 'table' or type(def.action) ~= 'function' then
        result = {installed = false, reason = 'vault_action_unavailable'}
    else
        local observer = (options and options.observer) or M.newObserver(options)
        local original = def.action
        def.action = M.wrapAction(observer, original, 'T_VAULT')
        M.observer = observer
        result = {installed = true, observer = observer}
    end
    M.installed = result
    return result
end

return M
