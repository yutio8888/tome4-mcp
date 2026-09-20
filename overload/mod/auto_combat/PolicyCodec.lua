-- GPL-3.0-or-later. X-doubleprime: canonical immutable policy snapshots.
--
-- WHY (see `tmp/mcp-play-support/astra-defect-family-addendum.md`): an exposed
-- populated Lua table cannot be made immutable — `__newindex` misses existing
-- keys, `rawset` bypasses it, and there is no sandbox. Therefore the
-- authoritative draft/approved/running policy state is a canonical BYTE string,
-- and every hash/evaluate/store transaction validates the exact value it uses
-- on a transaction-private working tree.
--
-- This module is the ONE policy-document constructor and the ONE content-hash
-- entry point:
--
--   prepare(raw, sink)  structural audit of the COMPLETE original input (typed
--                       fault, no key ever dropped) -> schema/catalog validation
--                       -> canonical bytes -> snapshot record
--   open(snapshot)      bounded decode + CANONICAL-BYTE check (the exact bytes
--                       must equal the canonical re-encoding) + full
--                       schema/catalog validation -> a transaction-private
--                       plain working tree
--   encode(value)       validate then encode
--   hash(value)         bytes/snapshot record, or a COMPLETE prepare audit
--                       then project (the same audit as prepare — XDP-REV-03)
--   copy(snapshot)      a detached decoded copy
--   normalise(record)   a fresh record re-derived from the exact bytes (the
--                       supplied `.hash` is discarded — XDP-REV-01/03)
--   matchesSnapshot(tree, bytes)
--                       exact transaction validation: no metatables anywhere
--                       in the tree AND the canonical re-encoding is exactly
--                       the recorded bytes (XDP-REV-02)
--
-- The **codec** (the typed byte encoding below) is NOT the content-hash
-- projection: the projection is the historical `PolicySchema.canonical`
-- algorithm (drop editable `updated`, arrays by positional index, object keys
-- sorted) kept here byte-compatible so the golden valid-input hash does not
-- move. It is a lexical local reached only through a validated tree.
--
-- Encoding (explicit, total, prefix-free, round-trippable):
--   * `n` -> null (also absent->key omitted in an object)
--   * `t` -> true, `f` -> false
--   * `#<digits>;` number, integral (`i`) or `%.17g` float (`d`):
--     `#i<digits>;` / `#d<number>;` — a self-delimiting `;`-terminated number,
--     so a number is never ambiguous with the following tag
--   * `s<len>:<bytes>` string (length-prefixed; no escapes needed)
--   * `a<len>:` array followed by `len` values (arrays are 1..n dense)
--   * `o<len>:` object followed by `len` (keylen ':' key value) pairs in
--     bytewise ascending key order
--   * empty containers: a table with no keys encodes as the empty OBJECT
--     (`o0:`). Lua plain values cannot distinguish an empty array from an empty
--     object; the canonical form is fixed, and the historical projection
--     already rendered `{}` as `{}`.
--   * key order is canonical and numbers have one exact representation, so
--     `encode(decode(encode(v)))` is a fixed point.
--   * the header carries the codec version and `open` refuses a foreign
--     header; the document itself must be schema `tome-auto-combat/v1`.
--   * metatables: only the JSON decoder's array marker is admitted; any other
--     metatable on caller data is a typed `invalid_metatable` fault.
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local Json=require 'mod.mcp_bridge.Json'
local M={}

M.SCHEMA=Schema.SCHEMA
M.VERSION=1
M.HEADER='xdp1\n'
M.MAX_DEPTH=Json.MAX_DEPTH
-- A hard bound on an accepted snapshot, so a corrupt/hostile byte string can
-- never drive an unbounded decode.
M.MAX_BYTES=4*1024*1024

-- Observability for the "validate before any encode/hash" contract. The
-- counters are the pre-registered evidence used by the regression suite: a
-- refused transaction must leave `projections` and `encodes` unchanged.
M.TRACE={validations=0,projections=0,encodes=0,decodes=0}
function M.stats()
    return {validations=M.TRACE.validations,projections=M.TRACE.projections,
        encodes=M.TRACE.encodes,decodes=M.TRACE.decodes}
end

local function keyLabel(key)
    if type(key)=='string' then return key end
    return '<'..type(key)..'>'
end
M.keyLabel=keyLabel

-- exact set `Json.encode` would later throw on, but audited here BEFORE any
-- encode so the fault is the typed constructor fault (XDP-REV-05). The single
-- source of truth is `Json.utf8Valid` (the validator `quote` itself uses).
local validUtf8=Json.utf8Valid

local function fault(code,input,cause,key)
    local out={code=code}
    if input~=nil then out.input=input end
    if cause~=nil then out.cause=cause end
    if key~=nil then out.key=key end
    return out
end

-- ---------------------------------------------------------------------------
-- 1. Complete structural audit of the ORIGINAL input (no lossy copy first).
-- ---------------------------------------------------------------------------

-- Deterministic classification of one table into array/object or a typed fault.
-- Never drops a key: an inadmissible key kind is a fault, not noise. Uses only
-- `pairs`, so it performs no `#`/`ipairs` on caller data.
local function classify(value)
    if Json.isArrayMarked(value) then
        local ok,count=Json.denseArray(value,0)
        if ok then
            if count==0 then return 'object' end
            return 'array',count
        end
        local cause,key=Json.denseFault(value)
        return nil,cause or 'not_array',key
    end
    local numeric,strings=0,0
    local maxKey=0
    local worstNumeric,worstExotic
    for key in pairs(value) do
        local kind=type(key)
        if kind=='string' then strings=strings+1
        elseif kind=='number' and key%1==0 and key>=1 then
            numeric=numeric+1
            if key>maxKey then maxKey=key end
        elseif kind=='number' then
            if worstNumeric==nil or key<worstNumeric then worstNumeric=key end
        else
            -- Exotic key: name only the TYPE, never a `tostring` address, so the
            -- diagnostic is deterministic across processes.
            if worstExotic==nil or kind<worstExotic then worstExotic=kind end
        end
    end
    if worstNumeric~=nil then return nil,'non_integer_key',worstNumeric end
    if worstExotic~=nil then return nil,'invalid_key','<'..worstExotic..'>' end
    if numeric>0 and strings>0 then return nil,'mixed_keys' end
    if numeric>0 then
        local ok,count=Json.denseArray(value,0)
        if ok then return 'array',count end
        local cause,key=Json.denseFault(value)
        return nil,cause or 'not_array',key
    end
    return 'object'
end

local function audit(value,path,depth,seen)
    if value==Json.null then return nil end
    local kind=type(value)
    if kind=='number' then
        if value~=value or value<=-math.huge or value>=math.huge then
            return fault('invalid_document',path,'non_finite_number')
        end
        return nil
    end
    if kind=='string' then
        if not validUtf8(value) then
            return fault('invalid_document',path,'invalid_utf8')
        end
        return nil
    end
    if kind=='boolean' then return nil end
    if kind~='table' then
        return fault('invalid_document',path,'unsupported_type',kind)
    end
    local mt=getmetatable(value)
    if mt~=nil and not Json.isArrayMarked(value) then
        -- Only the JSON decoder's own array marker is a legitimate metatable on
        -- caller data; anything else (a protected owned table, a hostile
        -- proxy, a tampered object) is refused rather than silently traversed.
        return fault('invalid_document',path,'invalid_metatable')
    end
    if depth>M.MAX_DEPTH then return fault('invalid_document',path,'too_deep') end
    if seen[value] then return fault('invalid_document',path,'cycle') end
    seen[value]=true
    local shape,detail,key=classify(value)
    if not shape then
        seen[value]=nil
        return fault('invalid_document',path,detail,key)
    end
    if shape=='array' then
        for index=1,detail do
            local child=audit(value[index],path..'['..index..']',depth+1,seen)
            if child then seen[value]=nil; return child end
        end
    else
        -- XDP-CLOSE-05 (Fix 5): select the reported invalid-UTF-8 key by a TOTAL
        -- ORDER (bytewise-smallest), not by `pairs` traversal order, so two
        -- invalid keys of different lengths yield one identical typed fault in
        -- every fresh process. This is a separate pre-scan placed BEFORE the
        -- base key loop; keeping the original loop body byte-identical is
        -- deliberate. A previous in-loop rewrite of `classify`/`audit` was
        -- exposed to a LuaJIT register-aliasing miscompile (a lone string key
        -- counted as `{numeric=1,strings=1}` => spurious `mixed_keys`) and had
        -- to be reverted; see the closure report's `jit_instability` evidence.
        do
            local bad
            for k in pairs(value) do
                if type(k)=='string' and not validUtf8(k) then
                    if bad==nil or k<bad then bad=k end
                end
            end
            if bad~=nil then
                seen[value]=nil
                return fault('invalid_document',path,'invalid_utf8_key','#'..#bad)
            end
        end
        local keys={}
        for k in pairs(value) do
            if type(k)=='string' and not validUtf8(k) then
                -- XDP-REV-05: an invalid-UTF-8 KEY would throw inside
                -- `Json.encode(key)` during the hash projection; refuse it
                -- typed here (the diagnostic carries the byte length, never
                -- the offending bytes). Unreachable for the UTF-8 case after
                -- the deterministic pre-scan above; kept as a defensive typed
                -- fault.
                seen[value]=nil
                return fault('invalid_document',path,'invalid_utf8_key','#'..#k)
            end
            keys[#keys+1]=k
        end
        table.sort(keys)
        for _,k in ipairs(keys) do
            local child=audit(value[k],path=='' and k or (path..'.'..k),depth+1,seen)
            if child then seen[value]=nil; return child end
        end
    end
    seen[value]=nil
    return nil
end

-- ---------------------------------------------------------------------------
-- 2. Canonical byte encoding.
-- ---------------------------------------------------------------------------

local function formatNumber(value)
    if value%1==0 and value>=-9007199254740992 and value<=9007199254740992 then
        return '#i'..string.format('%.0f',value)..';'
    end
    return '#d'..string.format('%.17g',value)..';'
end

local function encodeRaw(value,out)
    if value==Json.null or value==nil then out[#out+1]='n'; return end
    local kind=type(value)
    if kind=='boolean' then out[#out+1]=value and 't' or 'f'; return end
    if kind=='number' then out[#out+1]=formatNumber(value); return end
    if kind=='string' then out[#out+1]='s'..#value..':'..value; return end
    -- table (already audited): an array only when a non-empty dense 1..n run.
    local shape,detail=classify(value)
    if shape=='array' then
        out[#out+1]='a'..detail..':'
        for index=1,detail do encodeRaw(value[index],out) end
    else
        local keys={}
        for k in pairs(value) do keys[#keys+1]=k end
        table.sort(keys)
        out[#out+1]='o'..#keys..':'
        for _,k in ipairs(keys) do
            out[#out+1]=#k..':'..k
            encodeRaw(value[k],out)
        end
    end
end

local function encodeDocument(value)
    M.TRACE.encodes=M.TRACE.encodes+1
    local out={M.HEADER}
    encodeRaw(value,out)
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- 3. Bounded decode of canonical bytes.
-- ---------------------------------------------------------------------------

local function decodeDocument(bytes)
    if type(bytes)~='string' then return nil,fault('invalid_snapshot','snapshot','not_bytes') end
    if #bytes>M.MAX_BYTES then return nil,fault('invalid_snapshot','snapshot','too_large') end
    if bytes:sub(1,#M.HEADER)~=M.HEADER then
        return nil,fault('invalid_snapshot','snapshot','bad_header')
    end
    local pos=#M.HEADER+1
    local len=#bytes
    local function bad(cause) error({cause=cause},0) end
    local function readCount()
        local start=pos
        while pos<=len do
            local b=bytes:byte(pos)
            if b<48 or b>57 then break end
            pos=pos+1
        end
        if pos==start then bad('missing_length') end
        return tonumber(bytes:sub(start,pos-1))
    end
    local parse
    parse=function(depth)
        if depth>M.MAX_DEPTH then bad('too_deep') end
        if pos>len then bad('truncated') end
        local tag=bytes:sub(pos,pos)
        pos=pos+1
        if tag=='n' then return Json.null end
        if tag=='t' then return true end
        if tag=='f' then return false end
        if tag=='#' then
            -- Self-delimiting number: `#i<digits>;` or `#d<number>;`.
            local start=pos
            local stop=bytes:find(';',pos,true)
            if not stop then bad('unterminated_number') end
            local body=bytes:sub(start,stop-1)
            pos=stop+1
            local kind=body:sub(1,1)
            local digits=body:sub(2)
            if kind~='i' and kind~='d' then bad('invalid_number_tag') end
            if digits=='' then bad('invalid_number') end
            if kind=='i' and not digits:find('^%-?%d+$') then bad('invalid_integer') end
            if kind=='d' and not digits:find('^%-?%d+%.?%d*[eE]?[%+%-]?%d*$') then
                bad('invalid_number')
            end
            local value=tonumber(digits)
            if value==nil or value~=value or value<=-math.huge or value>=math.huge then
                bad('invalid_number')
            end
            if kind=='i' and value%1~=0 then bad('invalid_integer') end
            return value
        end
        if tag=='s' then
            local n=readCount()
            if bytes:sub(pos,pos)~=':' then bad('missing_string_colon') end
            pos=pos+1
            if n==nil or pos+n-1>len then bad('truncated_string') end
            local value=bytes:sub(pos,pos+n-1)
            pos=pos+n
            return value
        end
        if tag=='a' then
            local n=readCount()
            if bytes:sub(pos,pos)~=':' then bad('missing_array_colon') end
            pos=pos+1
            if n==nil then bad('invalid_count') end
            if n==0 then return {} end
            local out={}
            for index=1,n do out[index]=parse(depth+1) end
            return out
        end
        if tag=='o' then
            local n=readCount()
            if bytes:sub(pos,pos)~=':' then bad('missing_object_colon') end
            pos=pos+1
            if n==nil then bad('invalid_count') end
            local out={}
            local previous=nil
            for _=1,n do
                local klen=readCount()
                if bytes:sub(pos,pos)~=':' then bad('missing_key_colon') end
                pos=pos+1
                if klen==nil or pos+klen-1>len then bad('truncated_key') end
                local key=bytes:sub(pos,pos+klen-1)
                pos=pos+klen
                if previous~=nil and key<=previous then bad('unordered_key') end
                previous=key
                out[key]=parse(depth+1)
            end
            return out
        end
        bad('unknown_tag')
    end
    M.TRACE.decodes=M.TRACE.decodes+1
    local ok,value=pcall(parse,0)
    if not ok then
        local cause=(type(value)=='table' and value.cause) or 'malformed'
        return nil,fault('invalid_snapshot','snapshot',cause)
    end
    if pos<=len then return nil,fault('invalid_snapshot','snapshot','trailing_bytes') end
    return value
end

-- ---------------------------------------------------------------------------
-- 4. The historical content-hash projection (lexically private).
--
-- Exactly the projection `PolicySchema.canonical` used before this slice: drop
-- the editable `updated` metadata, arrays by positional index, object keys
-- sorted, strings JSON-escaped, everything else `tostring`. Byte-equal, so the
-- golden valid-input hash does not move.
-- ---------------------------------------------------------------------------

local function projection(value)
    if type(value)~='table' then
        if type(value)=='string' then return Json.encode(value) end
        return tostring(value)
    end
    if #value>0 then
        local parts={}
        for i=1,#value do parts[#parts+1]=projection(value[i]) end
        return '['..table.concat(parts,',')..']'
    end
    local keys={}
    for key in pairs(value) do keys[#keys+1]=key end
    table.sort(keys)
    local parts={}
    for _,key in ipairs(keys) do parts[#parts+1]=Json.encode(key)..':'..projection(value[key]) end
    return '{'..table.concat(parts,',')..'}'
end

local function digest(data)
    local ok,md5=pcall(require,'md5')
    if ok and type(md5)=='table' and md5.sumhexa then return md5.sumhexa(data) end
    local hash=2166136261
    for i=1,#data do
        hash=bit.bxor(hash,data:byte(i))
        hash=bit.band(hash*16777619,0xffffffff)
    end
    return string.format('%08x',hash)
end

local function hashValidated(value)
    M.TRACE.projections=M.TRACE.projections+1
    local copy={}
    for key,item in pairs(value) do if key~='updated' then copy[key]=item end end
    return digest(projection(copy))
end

-- The addendum's permitted private cache: structural validation results keyed by
-- EXACT immutable bytes + schema/validator version. A Lua string cannot be
-- mutated, so a cache hit proves the bytes were validated by this very codec
-- version; the decoded tree is still recreated per transaction (never leaked),
-- and world-dependent checks stay live. Bounded, with insertion-order eviction.
local CACHE={}
local CACHE_DIRTY=0
local CACHE_LIMIT=64
local function cacheKey(bytes) return M.VERSION..'\0'..bytes end
local function cacheGet(bytes)
    return CACHE[cacheKey(bytes)]
end
local function cachePut(bytes,hash)
    CACHE[cacheKey(bytes)]=hash
    CACHE_DIRTY=CACHE_DIRTY+1
    if CACHE_DIRTY>CACHE_LIMIT*2 then
        CACHE_DIRTY=0
        local count=0
        for _ in pairs(CACHE) do count=count+1 end
        if count>CACHE_LIMIT then
            -- Deterministic eviction: drop the bytewise-smallest third.
            local keys={}
            for key in pairs(CACHE) do keys[#keys+1]=key end
            table.sort(keys)
            for index=1,math.floor(#keys/3) do CACHE[keys[index]]=nil end
        end
    end
end
function M.cacheSize()
    local count=0
    for _ in pairs(CACHE) do count=count+1 end
    return count
end
function M.cacheClear()
    CACHE={}; CACHE_DIRTY=0
end

-- ---------------------------------------------------------------------------
-- 5. Public transaction API.
-- ---------------------------------------------------------------------------

local function verifySemantics(value)
    M.TRACE.validations=M.TRACE.validations+1
    local ok,errors=Schema.validate(value)
    if not ok then return nil,{code='invalid_policy',errors=errors} end
    local compatible,semantic=Catalog.verify(value)
    if not compatible then return nil,{code='invalid_policy',errors=semantic} end
    return true
end
M.verifySemantics=verifySemantics

-- Structural audit of an arbitrary caller value: `nil` when it is a complete,
-- JSON-representable document; otherwise a typed fault whose `input` is the
-- document-relative path (rooted at `rootLabel`, default `config`).
function M.audit(raw,rootLabel)
    rootLabel=rootLabel or 'config'
    if type(raw)~='table' or raw==Json.null then
        return fault('invalid_document',rootLabel,'not_a_table')
    end
    local audited=audit(raw,'',0,{})
    if audited then
        if audited.input=='' then audited.input=rootLabel
        else audited.input=audited.input end
        return audited
    end
    return nil
end

local function snapshotOf(bytes,tree)
    return {bytes=bytes,hash=hashValidated(tree),schema=tree.schema,
        id=type(tree.id)=='string' and tree.id or nil,version=M.VERSION}
end

-- Validate the COMPLETE original input, then encode it. Nothing is copied or
-- projected before the structural audit and the schema/catalog validation.
function M.prepare(raw,sink)
    if type(raw)~='table' or raw==Json.null then
        return nil,fault('invalid_policy',sink,'not_a_table')
    end
    local audited=M.audit(raw,'policy')
    if audited then return nil,audited end
    local valid,err=verifySemantics(raw)
    if not valid then
        err.input=sink
        return nil,err
    end
    local bytes=encodeDocument(raw)
    local tree=decodeDocument(bytes)
    if not tree then return nil,fault('invalid_snapshot',sink,'internal_encode') end
    return snapshotOf(bytes,tree)
end

-- Bounded decode + full current-schema validation -> a transaction-private
-- plain working tree (no metatables, so it stays engine-save-safe).
-- A cache hit (exact bytes + this codec version) skips the redundant structural
-- checks but still decodes a fresh tree for THIS transaction.
function M.open(snapshot)
    local bytes=type(snapshot)=='string' and snapshot
        or (M.isSnapshot(snapshot) and snapshot.bytes)
    if bytes==nil then return nil,fault('invalid_snapshot','open','not_a_snapshot') end
    local tree,err=decodeDocument(bytes)
    if not tree then return nil,err end
    local cached=cacheGet(bytes)
    if cached~=nil then return tree,nil,bytes,cached end
    -- XDP-REV-04: the authoritative byte form is CANONICAL. A decode whose
    -- exact bytes differ from the canonical re-encoding (alternate lexical
    -- forms: leading-zero counts/lengths, non-canonical number spellings) is
    -- refused typed instead of being kept as authoritative bytes.
    local ok,canonical=pcall(encodeDocument,tree)
    if not ok or canonical~=bytes then
        return nil,fault('invalid_snapshot','snapshot','noncanonical_bytes')
    end
    -- XDP-REV-05: a hostile byte string never produced by this codec can carry
    -- strings the hash projection could not JSON-encode; the decoded tree runs
    -- the SAME complete audit before validation (cached per exact bytes).
    local audited=audit(tree,'snapshot',0,{})
    if audited then
        return nil,fault('invalid_document','snapshot',audited.cause,audited.key)
    end
    local valid,semantic=verifySemantics(tree)
    if not valid then return nil,semantic end
    local hash=hashValidated(tree)
    cachePut(bytes,hash)
    return tree,nil,bytes,hash
end
M.decode=M.open

-- Validate then encode. A public raw wrapper validates or refuses.
function M.encode(value)
    local snapshot,err=M.prepare(value,'encode')
    if not snapshot then return nil,err end
    return snapshot.bytes
end

function M.isSnapshot(value)
    return type(value)=='table' and type(value.bytes)=='string'
        and type(value.hash)=='string'
end

-- XDP-REV-02: exact transaction validation of a working tree against the
-- bytes it claims to come from. A digest comparison is not sufficient: the
-- projection uses `pairs`, so inherited values supplied through a root
-- `__index` are invisible to it while the evaluator WOULD read them. The tree
-- is intact only when (a) no table anywhere in it carries a metatable and
-- (b) its canonical re-encoding is EXACTLY the recorded bytes.
local function noMetatables(value,depth,seen)
    if type(value)~='table' then return true end
    if getmetatable(value)~=nil then return false end
    if seen[value] then return true end
    if depth>M.MAX_DEPTH then return false end
    seen[value]=true
    for _,child in pairs(value) do
        if not noMetatables(child,depth+1,seen) then return false end
    end
    return true
end

function M.matchesSnapshot(tree,bytes)
    if type(tree)~='table' or type(bytes)~='string' then return false end
    if not noMetatables(tree,0,{}) then return false end
    local ok,re=pcall(encodeDocument,tree)
    if not ok then return false end
    return re==bytes
end

-- Hash a byte string / snapshot record (re-derived from the exact bytes), or a
-- raw table: the raw branch runs the SAME COMPLETE audit as `prepare` (XDP-REV-03)
-- so a value `prepare` refuses can never be hashed here, and a snapshot record is
-- never trusted for its recorded `.hash` (the hash is always re-derived from the
-- bytes; a tampered record whose bytes were never validated re-runs the full
-- transaction and is refused if invalid).
function M.hash(value)
    if type(value)=='table' and M.isSnapshot(value) then
        return M.hash(value.bytes)
    end
    if type(value)=='string' then
        local cached=cacheGet(value)
        if cached~=nil then return cached end
        local tree,err=M.open(value)
        if not tree then return nil,err end
        return cacheGet(value)
    end
    local snapshot,err=M.prepare(value,'hash')
    if not snapshot then return nil,err end
    return snapshot.hash
end

-- A detached decoded copy of a snapshot. Mutation of the result is harmless to
-- the authoritative bytes.
function M.copy(snapshot)
    local tree=select(1,M.open(snapshot))
    if not tree then return nil,fault('invalid_snapshot','copy','not_a_snapshot') end
    return tree
end

-- XDP-REV-01/03: a snapshot-shaped table is NEVER authority. Normalise it into
-- a FRESH record: the bytes are re-opened and re-validated under the CURRENT
-- schema, the hash is re-derived from the exact bytes, and the caller's
-- `.hash` (and the caller's table) is discarded. This is the single normalise
-- route every promotion/restore/wire ingress goes through.
function M.normalise(snapshot)
    if not M.isSnapshot(snapshot) then
        return nil,fault('invalid_snapshot','normalise','not_a_snapshot')
    end
    local tree,err=M.open(snapshot)
    if not tree then return nil,err end
    return snapshotOf(snapshot.bytes,tree)
end

-- The full canonical projection (INCLUDING editable `updated` metadata) of a
-- validated document. Validates first; a malformed value is refused typed.
-- Distinct from the content-hash projection, which drops `updated`.
function M.canonical(value)
    local snapshot,err=M.prepare(value,'canonical')
    if not snapshot then return nil,err end
    return projection(M.work(snapshot))
end

-- Open a snapshot record into a fresh transaction-private working tree WITHOUT
-- re-running the schema validator: the private exact-bytes/schema cache the
-- addendum allows. The bytes were validated when the record was created; a Lua
-- string cannot be mutated, so the only mutable value (the decoded tree) is
-- recreated, and the re-derived content hash must equal the record's recorded
-- hash (any byte/record tampering is refused typed).
function M.work(snapshot)
    if not M.isSnapshot(snapshot) then
        return nil,fault('invalid_snapshot','work','not_a_snapshot')
    end
    local tree,err=M.open(snapshot.bytes)
    if not tree then return nil,err end
    return tree
end

return M
