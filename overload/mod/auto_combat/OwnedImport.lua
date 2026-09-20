-- GPL-3.0-or-later. X-prime slice 1: the ONE constructor that accepts raw
-- assistant-import input.
--
-- Why this module exists (see `tmp/mcp-play-support/astra-defect-family-analysis.md`
-- and AGENTS.md "边界输入与引擎字段清单"): the recurring defect family is a caller
-- array that is only *partially* inspected and then measured as if complete.
-- Patching every hand-written ingress did not terminate the class. This module
-- inverts the ownership: translation never receives a raw caller table. It
-- receives an **owned** snapshot that only `M.construct` can produce, whose
-- required arrays were dense/closed validated over ALL keys *before* any
-- `#`/`ipairs`, and which is read-only and independent of later caller mutation.
--
-- Bounded claim (do NOT overstate it): this is a runtime invariant for the
-- owned production path, not structural impossibility in unrestricted Lua.
-- `construct` is the single construction choke point; `M.view`/`M.isOwned`
-- gate the owned type. A contributor could still write a *new* raw consumer
-- elsewhere; slice 2 migrates the remaining sinks (derived plans/candidate
-- sets, raised-spec semantics, transitions) behind the same ownership.
local Json=require 'mod.mcp_bridge.Json'
local M={}

-- Density cause vocabulary. Kept identical to `Json.denseArray`/
-- `Json.denseFault` (AGENTS.md checklist A) so there is one taxonomy.
M.CAUSES={not_array=true,hole=true,non_integer_key=true,key_beyond_dense_end=true}

-- The schema of caller-supplied arrays this import requires. Every entry is
-- validated by density before translation. `min` is the minimum dense length
-- (0 = an absent/empty list is a valid export). `condition` entries are
-- walked recursively (every `when` tree under a dense `talents` list).
--
-- Adding an ingress is a schema row, not new validation code: the loop below
-- is the only place that decides density.
M.SCHEMA={
    {path='assistant.addon_version',min=0},
    {path='assistant.tome_version',min=0},
    {path='sustains',min=0},
    {path='talents',min=0},
    {path='talents[].when',condition=true},
}

local OWNED_ROOT_MT={}
local FROZEN_MT={}
local function readOnly() error('owned import is read-only',2) end
-- `__newindex` only fires for keys absent from the real table; the deep copy is
-- a normal table, so `pairs`/`ipairs`/`#` keep working in Lua 5.1. The owned
-- type itself is the identity registry below ({}, not a table key), so no
-- sentinel key ever leaks into the caller's data or the hash.
OWNED_ROOT_MT.__newindex=readOnly
FROZEN_MT.__newindex=readOnly
local OWNED_ROOT_ID="owned-import-root"
local IDENTITIES=setmetatable({}, {__mode='k'})

local MAX_DEPTH=Json.MAX_DEPTH

local function fault(path,cause,key)
    local out={code='invalid_document',input=path,cause=cause}
    if key~=nil then out.key=key end
    return out
end

-- Deep copy of the caller input into private storage, preserving `Json.null`
-- and numeric keys. The copy is independent of the caller's table, so a
-- mutation after `construct` cannot change what the importer validated.
-- Bounded by `Json.MAX_DEPTH`.
local function copyValue(value,depth,seen,isRoot)
    if type(value)~='table' then return value end
    if value==Json.null then return Json.null end
    if depth>MAX_DEPTH then return nil,'too_deep' end
    if seen[value] then return seen[value] end
    local out={}
    seen[value]=out
    for k,v in pairs(value) do
        if type(k)~='table' then
            local copied,why=copyValue(v,depth+1,seen,false)
            if why then return nil,why end
            out[k]=copied
        end
    end
    setmetatable(out,isRoot and OWNED_ROOT_MT or FROZEN_MT)
    return out
end

local function resolve(root,path)
    local node=root
    for part in path:gmatch('[^.]+') do
        if type(node)~='table' then return nil end
        node=node[part]
    end
    return node
end

-- Dense/closed check of ONE caller array. `nil` means dense (or absent, where
-- absent is legal); otherwise a typed fault naming the input/cause/key. The
-- density decision itself lives only in `Json.denseArray`/`Json.denseFault`.
local function densityFault(path,value)
    local ok,rawCause=Json.denseArray(value,0)
    if ok then return nil end
    local cause,key=Json.denseFault(value)
    return fault(path,cause or rawCause,key)
end

-- Recursively validate the `all`/`any` lists of a condition tree. A malformed
-- condition array is a WHOLE-IMPORT fault (never "drop this one rule"), which
-- is the property the previous per-rule dropping could not provide.
local function conditionFault(cond,path,depth)
    if type(cond)~='table' or cond==Json.null then return nil end
    if depth>MAX_DEPTH then return nil end
    if cond.all~=nil then
        local f=densityFault(path..'.all',cond.all)
        if f then return f end
        local _,count=Json.denseArray(cond.all,0)
        for i=1,count do
            f=conditionFault(cond.all[i],path..'.all['..i..']',depth+1)
            if f then return f end
        end
        return nil
    end
    if cond.any~=nil then
        local f=densityFault(path..'.any',cond.any)
        if f then return f end
        local _,count=Json.denseArray(cond.any,0)
        for i=1,count do
            f=conditionFault(cond.any[i],path..'.any['..i..']',depth+1)
            if f then return f end
        end
        return nil
    end
    if cond['not']~=nil then
        return conditionFault(cond['not'],path..'.not',depth+1)
    end
    return nil
end

local function validateSchema(root)
    for _,row in ipairs(M.SCHEMA) do
        if row.condition then
            -- for each dense `talents` entry, validate the `when` tree.
            local talents=resolve(root,'talents')
            if type(talents)=='table' and talents~=Json.null then
                local _,count=Json.denseArray(talents,0)
                for i=1,count do
                    local entry=talents[i]
                    if type(entry)=='table' and entry~=Json.null then
                        if entry.when~=nil then
                            local f=conditionFault(entry.when,'talents['..i..'].when',0)
                            if f then return f end
                        end
                    end
                end
            end
        else
            local value=resolve(root,row.path)
            -- An absent optional list is legal; a present non-array is not.
            if value~=nil then
                local f=densityFault(row.path,value)
                if f then return f end
            end
        end
    end
    return nil
end

-- THE single construction choke point. Only this function accepts raw caller
-- input. Returns the owned snapshot, or `nil, fault` (a typed
-- `invalid_document` naming the input/cause/key) with nothing downstream run.
function M.construct(raw)
    if type(raw)~='table' or raw==Json.null then
        return nil,fault('config','not_array')
    end
    local snapshot,why=copyValue(raw,0,{},true)
    if not snapshot then return nil,fault('config',why or 'too_deep') end
    local f=validateSchema(snapshot)
    if f then return nil,f end
    IDENTITIES[snapshot]=OWNED_ROOT_ID
    return snapshot
end

-- The owned type gate: identity, not a self-declared key. `view` is the only
-- way a consumer obtains the input; a raw caller table is not registered and
-- cannot be viewed.
function M.isOwned(value)
    return type(value)=='table' and IDENTITIES[value]==OWNED_ROOT_ID
end

function M.view(owned)
    if not M.isOwned(owned) then return nil,{code='import_not_owned',input='import'} end
    return owned
end

-- Convenience for callers that already hold a raw table and want the typed
-- fault shape back (the service path and tests). Never bypasses `construct`.
function M.requireOwned(value)
    if M.isOwned(value) then return value end
    local owned,f=M.construct(value)
    if not owned then return nil,f end
    return owned
end

return M
