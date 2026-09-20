-- OwnedImport + AssistantAdapter import-refusal (X-prime slice 1).
--
-- Pins the vertical slice: a malformed required array refuses the WHOLE import
-- with a typed fault (input/cause/key), produces NO draft/hash/store, and a
-- valid import round-trips to the pinned policy hash.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
package.path=root..'/overload/?.lua;'..package.path
local Owned=require 'mod.auto_combat.OwnedImport'
local Adapter=require 'mod.auto_combat.AssistantAdapter'
local Schema=require 'mod.auto_combat.PolicySchema'
local Service=require 'mod.auto_combat.AutoCombatService'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local fixture_dir=root..'/tests/fixtures/assistant/'
local function fixture(name)
    local file=assert(io.open(fixture_dir..name,'r'))
    local text=file:read('*a');file:close()
    return Json.decode(text)
end
local function fresh() return fixture('anorithil_pinned.json') end

-- Pinned before/after hash. The hash was captured on the pre-change tree
-- (`main@ded8e1a` AssistantAdapter) and must not move: the ownership slice is
-- behaviour-preserving for a valid import.
local PINNED_HASH='2836a530'

-- Constructor primitive ------------------------------------------------------
do
    local owned,fault=Owned.construct(fresh())
    check(owned~=nil and fault==nil,'a valid export constructs an owned snapshot')
    check(Owned.isOwned(owned),'the constructed value is the owned type')
    check(getmetatable(owned)~=getmetatable({}),'the owned snapshot uses private metatable state')
    -- The owned copy is a private deep snapshot: adding a NEW key is blocked, and
    -- it never aliases caller storage. Lua 5.1 cannot make an existing key
    -- read-only (no `__newindex` on an assigned key), so the guarantee is
    -- "private + validated + non-aliased", NOT "impossible to mutate".
    local ok=pcall(function() owned.added_key=1 end)
    check(ok==false,'the owned snapshot refuses a new key')
    check(Owned.isOwned(owned),'the owned type survives ordinary reads')
    -- The owned copy is independent of later caller mutation.
    local raw=fresh()
    local snap=assert(Owned.construct(raw))
    raw.talents[1].talent='T_MUTATED'
    check(snap.talents[1].talent~=nil and snap.talents[1].talent:find('^T_')~=nil,
        'the owned snapshot does not alias caller storage')
    -- A raw table cannot be viewed as owned.
    local view,err=Owned.view(fresh())
    check(view==nil and err.code=='import_not_owned','view refuses a raw table')
    check(Owned.view(owned)==owned,'view returns the owned snapshot')
end

-- Every required array refuses the whole import with a typed fault -----------
local function refused(config,input,cause)
    local calls=0
    local real=Schema.hash
    Schema.hash=function(...) calls=calls+1; return real(...) end
    local result=Adapter.translate(config)
    Schema.hash=real
    check(result.ok==false,'import refused: '..tostring(input))
    check(result.draft==nil,'no draft is produced')
    check(result.error and result.error.code=='invalid_document','a typed invalid_document fault')
    check(result.error.input==input,'the fault names the input '..tostring(input)
        ..' (got '..tostring(result.error.input)..')')
    check(result.error.cause==cause,'the fault names the cause '..tostring(cause)
        ..' (got '..tostring(result.error.cause)..')')
    check(calls==0,'zero hash calls for a refused import')
    return result.error
end

-- The scalar-version defect: a scalar (or nil) tuple is cause=not_array.
do
    local c=fresh(); c.assistant.addon_version='2.3.9'
    refused(c,'assistant.addon_version','not_array')
    c=fresh(); c.assistant.tome_version='1.7.4'
    refused(c,'assistant.tome_version','not_array')
    c=fresh(); c.assistant.addon_version=nil
    refused(c,'assistant.addon_version','not_array')
    -- A hole beyond the dense end carries the offending key.
    c=fresh(); c.assistant.addon_version={[1]=2,[2]=3,[4]=9}
    local err=refused(c,'assistant.addon_version','key_beyond_dense_end')
    check(err.key==4,'the sparse version fault names the offending key')
    c=fresh(); c.assistant.addon_version={[1]=2,[2]=3,[3]=9,extra=true}
    refused(c,'assistant.addon_version','non_integer_key')
end

-- cond.all / cond.any before any #/ipairs ------------------------------------
do
    local c=fresh(); c.talents[1].when={all={[1]={hp_pct={lt=70}},[3]={hp_pct={lt=50}}}}
    local err=refused(c,'talents[1].when.all','key_beyond_dense_end')
    check(err.key==3,'the sparse condition fault names the offending key')
    c=fresh(); c.talents[1].when={all='x'}
    refused(c,'talents[1].when.all','not_array')
    c=fresh(); c.talents[1].when={any={[1]={hp_pct={lt=70}},[1.5]={hp_pct={lt=50}}}}
    refused(c,'talents[1].when.any','non_integer_key')
    -- Nested: a malformed array deeper in the tree still terminates the import.
    c=fresh(); c.talents[1].when={all={{all={[1]={hp_pct={lt=70}},[4]={hp_pct={lt=50}}}},{always={}}}}
    refused(c,'talents[1].when.all[1].all','key_beyond_dense_end')
end

-- config.sustains / config.talents before any #/ipairs -----------------------
do
    local c=fresh(); c.sustains={[1]={talent='T_CHANT_OF_FORTRESS'},[3]={talent='T_CHANT_OF_FORTRESS'}}
    refused(c,'sustains','key_beyond_dense_end')
    c=fresh(); c.talents={[1]=c.talents[1],[3]=c.talents[2]}
    refused(c,'talents','key_beyond_dense_end')
    c=fresh(); c.talents='nope'
    refused(c,'talents','not_array')
    c=fresh(); c.sustains={1,2,[5]=3}
    refused(c,'sustains','key_beyond_dense_end')
end

-- The whole import is refused: no draft, no hash, no store -------------------
do
    local svc=Service.new()
    local c=fresh(); c.assistant.addon_version='2.3.9'
    local result=Service.handle(svc,'import_assistant',{config=c,store=true})
    check(result.ok==false and result.error.code=='invalid_document',
        'the service refuses a malformed import with the typed fault')
    check(svc.store.draft==nil and svc.store.approved==nil and svc.store.running==nil,
        'a refused import stores nothing')
    check(svc.revision==0,'a refused import does not advance the revision')
    -- A valid import still works and stores on request.
    local good=Service.handle(svc,'import_assistant',{config=fresh(),store=true})
    check(good.ok==true and good.imported==true,'a valid import still succeeds')
    check(svc.store.draft~=nil,'a valid import stores on explicit request')
    check(result.error.details and result.error.details.input=='assistant.addon_version',
        'the service refusal still names the offending input')
end

-- Raw-path unreachability: the hash choke point rejects an unowned policy ----
do
    local good=Adapter.translate(fresh())
    check(good.ok==true,'the valid export translates')
    check(Adapter.hashPolicy(good.draft)==PINNED_HASH,
        'an imported draft hashes to the pinned content hash')
    check(Adapter.isOwnedPolicy(good.draft),'the imported draft is registered as owned')
    -- A raw policy table cannot be hashed by the choke point.
    local raw={schema=Schema.SCHEMA,id='x',name='x',
        limits={max_actions_per_tick=1},safety={},targeting={default='nearest_hostile'},
        sustains={},rules={{id='r',priority=1,when={always={}},
            ['then']={action='attack'}}}}
    local ok=pcall(Adapter.hashPolicy,raw)
    check(ok==false,'a raw table is not hashable through the choke point')
end

-- Round-trip: the valid import keeps the pre-change hash ---------------------
do
    local result=Adapter.translate(fresh())
    check(result.ok==true,'the pinned export imports')
    check(result.draft.__mcp_owned_policy==nil,'ownership is not stored on the policy bytes')
    check(Schema.hash(result.draft)==PINNED_HASH,
        'the raw schema hash matches the pinned content hash (before == after)')
    check(result.hash==PINNED_HASH,
        'the importer still reports the pinned content hash')
    -- Determinism.
    check(Adapter.translate(fresh()).hash==PINNED_HASH,'translation stays deterministic')
end

print('Owned import (X-prime slice 1): '..checks..' checks passed')
