-- GPL-3.0-or-later. Source pins: advisory re-review metadata (NO-AUDIT, v1.6).
--
-- The version-pinned manifest records the source files/hashes and definition
-- lines it was curated from. Under the no-strict-audit principle (AGENTS.md,
-- design §8.3, factory design §1/§3.1) Lua is dynamic: any runtime function may
-- be replaced by another addon, so the project neither guarantees nor needs to
-- guarantee that a runtime entry is the pristine native implementation, and is
-- not responsible for other plugins' broken implementations.
--
-- Consequently the source hashes and builder/getter identities are **advisory
-- telemetry**, never a runtime gate. The guard and the planner call the game's
-- actual builders/getters as normal entrypoints; a missing/erroring/unusable
-- value is a typed derivation-unknown, not a source-drift rejection.
--
-- This module therefore exposes:
--   * `M.review(sources,...)` / `M.identity(...)` — pure advisory diagnostics
--     that report source/builder drift for the maintainers. They never block.
--   * `M.telemetry(...)` — the same information as a structured record.
-- It is pure apart from the injected readers: unit tests supply a spoofed
-- `read`/`digest` pair, the runtime supplies `fs.readAll` and the engine `md5`.
local M={}
-- Kept only as a descriptive label for the advisory review; it is never used as
-- a runtime gate reason.
M.ADVISORY_DRIFT='adapter_source_drift'

-- Diagnose one pinned entry. `read(path)` returns the file text or nil;
-- `digest(text)` returns a lowercase hex hash. Advisory only.
local function checkFile(pin,read,digest)
    if type(pin)~='table' or type(pin.path)~='string' or type(pin.md5)~='string' then
        return nil,'malformed_pin','malformed pin'
    end
    local ok,text=pcall(read,pin.path)
    if not ok or type(text)~='string' then
        return nil,'source_unreadable',pin.path..':unreadable'
    end
    local hashed,actual=pcall(digest,text)
    if not hashed or actual~=pin.md5 then
        return nil,'source_changed',pin.path..':hash'
    end
    return true
end

-- Advisory source review: returns a list of findings (never raises, never
-- blocks). `drift` is true when at least one pin no longer matches. Callers may
-- log this; they must not use it to deny an action.
function M.review(sources,read,digest,expected)
    local findings={}
    local function note(kind,detail)
        findings[#findings+1]={kind=kind,detail=detail}
    end
    if type(sources)~='table' or type(sources.engine)~='table' or type(sources.talents)~='table' then
        note('advisory_source_table','missing engine/talents table')
    elseif sources.schema~='tome-effect-manifest-sources/v1' then
        note('advisory_source_schema',tostring(sources.schema))
    else
        local expected_version=expected and expected.game_version
        if expected_version and sources.game_version~=expected_version then
            note('advisory_game_version',tostring(sources.game_version))
        end
        if type(read)~='function' or type(digest)~='function' then
            note('advisory_hash_service_unavailable','no read/digest')
        else
            local keys={}
            for key in pairs(sources.engine) do keys[#keys+1]='engine:'..key end
            for key in pairs(sources.talents) do keys[#keys+1]='talent:'..key end
            table.sort(keys)
            for _,key in ipairs(keys) do
                local kind,name=key:match('^(%a+):(.+)$')
                local entry=kind=='engine' and sources.engine[name] or sources.talents[name]
                local pins=entry.files or {entry}
                for _,pin in ipairs(pins) do
                    local ok,code,path=checkFile(pin,read,digest)
                    if not ok then note(code,kind..':'..name..':'..tostring(path)) end
                end
            end
        end
    end
    return {drift=#findings>0,findings=findings}
end

-- Advisory builder/definition review: a missing definition or a builder whose
-- source/line no longer matches its pin is reported, never rejected. `getDef`
-- returns the live talent definition table.
function M.identity(manifest,getDef)
    local findings={}
    if type(manifest)~='table' or type(manifest.ENTRIES)~='table' or type(getDef)~='function' then
        return {drift=true,findings={{kind='identity_unavailable',detail='bad arguments'}},baselines={}}
    end
    local names={}
    for talent in pairs(manifest.ENTRIES) do names[#names+1]=talent end
    table.sort(names)
    local baselines={}
    for _,talent in ipairs(names) do
        local entry=manifest.ENTRIES[talent]
        local expects=entry.conformance and entry.conformance.builder
        local def=getDef(talent)
        if type(def)~='table' then
            findings[#findings+1]={talent=talent,kind='definition_missing'}
        elseif expects==nil then
            findings[#findings+1]={talent=talent,kind='builder_undeclared'}
        elseif expects==true then
            local builder=def.target
            if type(builder)~='function' then
                findings[#findings+1]={talent=talent,kind='builder_missing'}
            else
                local pin=entry.source and entry.source.builder
                if type(pin)=='table' and type(pin.path)=='string' and type(pin.line)=='number' then
                    local info=debug.getinfo(builder,'S')
                    if type(info)~='table' or info.what~='Lua'
                        or info.source~='@'..pin.path or info.linedefined~=pin.line then
                        findings[#findings+1]={talent=talent,kind='builder_moved'}
                    end
                end
                baselines[talent]=builder
            end
        elseif def.target~=nil then
            findings[#findings+1]={talent=talent,kind='builder_unexpected'}
        end
    end
    return {drift=#findings>0,findings=findings,baselines=baselines}
end

-- Advisory runtime telemetry hook. Returns a structured record; the caller may
-- log it. It always returns true so it can never gate a decision, and it never
-- throws. `opts` = {sources=,read=,digest=,expected=,identity=,manifest=}.
function M.telemetry(opts)
    opts=opts or {}
    local record={advisory=true}
    local ok_source,source=pcall(M.review,opts.sources,opts.read,opts.digest,opts.expected)
    record.source=ok_source and source or {drift=true,findings={{kind='review_error'}}}
    if opts.identity and opts.manifest then
        local ok_id,identity=pcall(M.identity,opts.manifest,opts.identity)
        record.identity=ok_id and identity or {drift=true,findings={{kind='identity_error'}}}
    end
    return record
end

function M.reset() end

return M
