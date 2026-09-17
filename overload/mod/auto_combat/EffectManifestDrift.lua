-- GPL-3.0-or-later. Source-drift detection for the v2 effect manifest.
--
-- The manifest is only trustworthy while the audited source files still match
-- the hashes and definition lines it was generated from, and while the live
-- talent definitions still expose the pinned target builders. The immutable
-- file hashes are verified once per session; the live identity check is re-run
-- before every guarded action. Any mismatch fails closed with
-- `adapter_source_drift` and the caller must never fall back to stale metadata.
--
-- It is pure apart from the injected readers: unit tests supply a spoofed
-- `read`/`digest` pair, the runtime supplies `fs.readAll` and the engine `md5`.
local M={}
M.REASON='adapter_source_drift'

-- Diagnose one pinned entry. `read(path)` returns the file text or nil;
-- `digest(text)` returns a lowercase hex hash. Returns true or nil,reason,path.
local function checkFile(pin,read,digest)
    if type(pin)~='table' or type(pin.path)~='string' or type(pin.md5)~='string' then
        return nil,'adapter_source_drift','malformed pin'
    end
    local ok,text=pcall(read,pin.path)
    if not ok or type(text)~='string' then
        return nil,'adapter_source_drift',pin.path..':unreadable'
    end
    local hashed,actual=pcall(digest,text)
    if not hashed or actual~=pin.md5 then
        return nil,'adapter_source_drift',pin.path..':hash'
    end
    return true
end

-- Verify every pinned engine-semantics and talent source file, plus the
-- schema/version identity that ties the generated table to the curated model.
function M.verify(sources,read,digest,expected)
    if type(sources)~='table' or type(sources.engine)~='table' or type(sources.talents)~='table' then
        return nil,M.REASON,'source_table'
    end
    if sources.schema~='tome-effect-manifest-sources/v1' then
        return nil,M.REASON,'source_schema'
    end
    local expected_version=expected and expected.game_version
    if expected_version and sources.game_version~=expected_version then
        return nil,M.REASON,'game_version'
    end
    local keys={}
    for key in pairs(sources.engine) do keys[#keys+1]='engine:'..key end
    for key in pairs(sources.talents) do keys[#keys+1]='talent:'..key end
    table.sort(keys)
    for _,key in ipairs(keys) do
        local kind,name=key:match('^(%a+):(.+)$')
        local entry=kind=='engine' and sources.engine[name] or sources.talents[name]
        local pins=entry.files or {entry}
        for _,pin in ipairs(pins) do
            local ok,reason,path=checkFile(pin,read,digest)
            if not ok then return nil,reason,kind..':'..name..':'..tostring(path) end
        end
    end
    return true
end

-- Trusted builder objects, captured on the first verified sight per session.
-- Object identity (`rawequal`) is the only accepted proof: Lua bytecode does not
-- include captured upvalue values, so a byte-identical dump cannot be trusted.
-- A distinct object is rejected; a legitimate reload resets the baseline only at
-- an explicit session boundary (`ensure` with a new key).
local baselines={}
local active_key=nil

-- Identity/closure: every manifest entry must expose its declared target
-- expectation. `conformance.builder` is `true` (a pinned native builder),
-- `false` (an action-local target, so no builder) or `'none'` (a self/no-target
-- entry). Every entry requires a live definition; a missing definition, a
-- missing/undeclared/unpinned builder, an unexpected builder, or any distinct
-- (even byte-identical) replacement closure all fail closed. The live check runs
-- on every guarded action so a mutation after a cached hash success is caught.
function M.identity(manifest,getDef)
    if type(manifest)~='table' or type(manifest.ENTRIES)~='table' or type(getDef)~='function' then
        return nil,M.REASON,'identity_unavailable'
    end
    local names={}
    for talent in pairs(manifest.ENTRIES) do names[#names+1]=talent end
    table.sort(names)
    for _,talent in ipairs(names) do
        local entry=manifest.ENTRIES[talent]
        local expects=entry.conformance and entry.conformance.builder
        if expects==nil then return nil,M.REASON,talent..':builder_undeclared' end
        local def=getDef(talent)
        if type(def)~='table' then return nil,M.REASON,talent..':definition_missing' end
        if entry.kind=='movement' then
            -- MAF-REV-06 (no-strict-audit): a movement adapter uses the game's
            -- live builder/getters as normal entrypoints. There is no identity
            -- or digest gate here; an erroring/missing getter fails the
            -- derivation instead. The generated `action`/`getters`/`ranges`
            -- pins stay advisory re-review metadata only.
        else
            local builder=def.target
            if expects==true then
                if type(builder)~='function' then return nil,M.REASON,talent..':builder_missing' end
                local pin=entry.source and entry.source.builder
                if type(pin)~='table' or type(pin.path)~='string' or type(pin.line)~='number' then
                    return nil,M.REASON,talent..':builder_unpinned'
                end
                local info=debug.getinfo(builder,'S')
                if type(info)~='table' or info.what~='Lua'
                    or info.source~='@'..pin.path or info.linedefined~=pin.line then
                    return nil,M.REASON,talent..':builder_replaced'
                end
                local baseline=baselines[talent]
                if baseline==nil then
                    baselines[talent]=builder
                elseif not rawequal(baseline,builder) then
                    -- A distinct object (same source/line, possibly identical
                    -- bytecode) is a replacement; never overwrite the baseline.
                    return nil,M.REASON,talent..':builder_replaced'
                end
            else
                -- `false` and `'none'` both require the absence of a target builder.
                if builder~=nil then return nil,M.REASON,talent..':builder_unexpected' end
            end
        end
    end
    return true
end

-- Only immutable file hashes are cached per session; the live identity check is
-- re-run before every guarded action so a later definition mutation fails closed.
local hash_cache={}

function M.reset()
    baselines={}
    active_key=nil
    hash_cache={}
end

-- Runtime check. `key` distinguishes contexts (for example the session id); a
-- new key is an explicit lifecycle boundary and resets the trusted builder
-- baseline. `opts` = {sources=,read=,digest=,identity=,manifest=}.
function M.ensure(key,opts)
    if key~=active_key then
        active_key=key
        baselines={}
    end
    local cached=hash_cache[key]
    local ok,reason,detail
    if cached then
        ok,reason,detail=cached.ok,cached.reason,cached.detail
    else
        ok,reason,detail=M.verify(opts.sources,opts.read,opts.digest,opts.expected)
        hash_cache[key]={ok=ok==true,reason=reason,detail=detail}
    end
    if not ok then return false,reason,detail end
    if opts.identity then
        local id_ok,id_reason,id_detail=M.identity(opts.manifest,opts.identity)
        if not id_ok then return false,id_reason,id_detail end
    end
    return true,nil,nil
end

return M
