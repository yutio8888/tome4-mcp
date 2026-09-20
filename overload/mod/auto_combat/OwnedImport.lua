-- GPL-3.0-or-later. X-doubleprime: the ONE constructor that accepts raw
-- assistant-import input.
--
-- Why this module exists (see `tmp/mcp-play-support/astra-defect-family-addendum.md`
-- and AGENTS.md "边界输入与引擎字段清单"): the recurring defect family is a caller
-- array that is only *partially* inspected and then measured as if complete.
-- Patching every hand-written ingress did not terminate the class. This module
-- keeps the ownership inversion — translation never receives a raw caller
-- table — but the X-prime table-identity certificate is GONE (XPS1-R2-01/02/03):
-- an exposed populated Lua table cannot be made immutable, so identity proves
-- only a past check. What remains is:
--
--   * a COMPLETE structural audit of the original input (nothing dropped, no
--     lossy copy before validation; XPS1-R2-03),
--   * a private deep copy (no aliasing to caller storage), and
--   * a per-array-row element validator that really runs (XPS1-R2-04).
--
-- The copy is a plain table with no metatable: (a) a Lua 5.1 proxy cannot
-- support `#`/`ipairs`, and (b) the value must stay engine-save-safe. Because
-- no Lua-side immutability exists, the authoritative policy state is canonical
-- BYTES (`PolicyCodec`) and every hash/evaluate/store transaction validates the
-- exact value it uses.
local Json=require 'mod.mcp_bridge.Json'
local Codec=require 'mod.auto_combat.PolicyCodec'
local M={}

-- Density cause vocabulary. Kept identical to `Json.denseArray`/
-- `Json.denseFault` (AGENTS.md checklist A) so there is one taxonomy.
M.CAUSES={not_array=true,hole=true,non_integer_key=true,key_beyond_dense_end=true}
-- Element-shape cause vocabulary: a schema row flagged `element=true`
-- requires EVERY element to be a table (a non-table element is a WHOLE-IMPORT
-- fault, never a silently dropped entry). XPS1-R2-04: the flag is enforced by
-- `validateSchema` below, not dead.
M.ELEMENT_CAUSES={invalid_element=true}

-- The schema of caller-supplied arrays this import requires. Every entry is
-- validated by density (and, when flagged, element shape) before translation.
-- `condition` entries are walked recursively (every `when` tree under a dense
-- `talents` list).
--
-- Adding an ingress is a schema row, not new validation code: the loop below
-- is the only place that decides density and element shape.
M.SCHEMA={
    {path='assistant.addon_version',min=0,scalar=true},
    {path='assistant.tome_version',min=0,scalar=true},
    {path='sustains',min=0,element=true},
    {path='talents',min=0,element=true},
    {path='talents[].when',condition=true},
}

local MAX_DEPTH=Json.MAX_DEPTH

local function fault(path,cause,key)
    local out={code='invalid_document',input=path,cause=cause}
    if key~=nil then out.key=key end
    return out
end

-- Private deep copy of the caller input into fresh storage, preserving
-- `Json.null`. Every key is copied — an inadmissible (table/exotic) KEY is a
-- typed `invalid_key` fault, NEVER a silently skipped entry (XPS1-R2-03: the
-- previous copyValue dropped table-valued keys, so a malformed original could
-- be validated as a smaller, "valid" document).
local function copyValue(value,depth,seen)
    if type(value)~='table' then return value end
    if value==Json.null then return Json.null end
    if depth>MAX_DEPTH then return nil,'too_deep' end
    if seen[value] then return nil,'cycle' end
    seen[value]=true
    local out={}
    for k,v in pairs(value) do
        local kind=type(k)
        if kind~='string' and not (kind=='number' and k%1==0 and k>=1) then
            seen[value]=nil
            return nil,'invalid_key',Codec.keyLabel(k)
        end
        local copied,why,which=copyValue(v,depth+1,seen)
        if copied==nil and why then seen[value]=nil; return nil,why,which end
        out[k]=copied
    end
    seen[value]=nil
    return out
end
M.copyValue=copyValue

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
-- condition array is a WHOLE-IMPORT fault (never "drop this one rule").
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

-- XPS1-R2-04: the schema rows now really enforce `element` (and `scalar` for
-- the version tuples). A row flagged `element=true` refuses the whole import
-- with `invalid_element` + the offending index when any element is not a table;
-- a `scalar=true` row refuses a non-scalar element.
local function elementFault(row,value)
    local _,count=Json.denseArray(value,0)
    for index=1,count do
        local element=value[index]
        if row.element then
            if type(element)~='table' or element==Json.null then
                return fault(row.path,'invalid_element',index)
            end
        elseif row.scalar then
            local kind=type(element)
            if kind~='string' and kind~='number' then
                return fault(row.path,'invalid_element',index)
            end
        end
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
                if row.element or row.scalar then
                    f=elementFault(row,value)
                    if f then return f end
                end
            end
        end
    end
    return nil
end
M.validateSchema=validateSchema

-- THE single construction choke point. Only this function accepts raw caller
-- input. Returns the private snapshot, or `nil, fault` (typed
-- `invalid_document` naming the input/cause/key) with nothing downstream run.
-- Order (XPS1-R2-03): audit the ORIGINAL structure, then copy, then validate the
-- copy's schema rows — no hash/encode happens here, and nothing is dropped.
function M.construct(raw)
    if type(raw)~='table' or raw==Json.null then
        return nil,fault('config','not_array')
    end
    local audited=Codec.audit(raw,'config')
    if audited then return nil,audited end
    local snapshot,why,which=copyValue(raw,0,{})
    if not snapshot then return nil,fault('config',why or 'too_deep',which) end
    local f=validateSchema(snapshot)
    if f then return nil,f end
    return snapshot
end

-- A typed fault for a raw table that fails the same schema, without building a
-- snapshot (used by tests and by callers that only want the diagnosis).
function M.check(raw)
    local owned,faultValue=M.construct(raw)
    if owned then return true end
    return nil,faultValue
end

-- Convenience for callers that already hold a raw table and want the typed
-- fault shape back. Never bypasses `construct`.
function M.requireOwned(value)
    return M.construct(value)
end

return M
