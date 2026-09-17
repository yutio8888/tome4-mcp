-- GPL-3.0-or-later. Source-drift detection for the v2 effect manifest.
--
-- The manifest is only trustworthy while the audited source files still match
-- the hashes and definition lines it was generated from. This module performs
-- that check once per session and caches the verdict; any mismatch fails closed
-- with `adapter_source_drift` and the caller must never fall back to stale
-- metadata.
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

-- Identity/closure: every entry that declares a native builder must expose the
-- *pinned* builder function (same source path and definition line), and every
-- entry that declares an action-local target must not expose one. A same-type
-- replacement loaded from another file/line fails closed, and a missing
-- definition fails closed instead of being skipped.
function M.identity(manifest,getDef)
    if type(manifest)~='table' or type(manifest.ENTRIES)~='table' or type(getDef)~='function' then
        return nil,M.REASON,'identity_unavailable'
    end
    local names={}
    for talent in pairs(manifest.ENTRIES) do names[#names+1]=talent end
    table.sort(names)
    for _,talent in ipairs(names) do
        local entry=manifest.ENTRIES[talent]
        local expects=entry.conformance
        if expects and expects.builder~=nil then
            local def=getDef(talent)
            if type(def)~='table' then return nil,M.REASON,talent..':definition_missing' end
            local builder=def.target
            if expects.builder then
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
            else
                if builder~=nil then return nil,M.REASON,talent..':builder_unexpected' end
            end
        end
    end
    return true
end

local cached={key=nil,ok=nil,reason=nil,detail=nil}

function M.reset()
    cached={key=nil,ok=nil,reason=nil,detail=nil}
end

-- Memoized runtime check. `key` distinguishes contexts (for example the
-- session id); `opts` = {sources=,read=,digest=,identity=,manifest=}.
function M.ensure(key,opts)
    if cached.key==key and cached.ok~=nil then return cached.ok,cached.reason,cached.detail end
    local ok,reason,detail=M.verify(opts.sources,opts.read,opts.digest,opts.expected)
    if ok and opts.identity then
        ok,reason,detail=M.identity(opts.manifest,opts.identity)
    end
    cached={key=key,ok=ok==true,reason=reason,detail=detail}
    return cached.ok,cached.reason,cached.detail
end

return M
